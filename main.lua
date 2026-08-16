--[[
    Sentence Experiment for KOReader

    Experimental plugin for investigating whether visually salient
    sentence boundaries change the reading experience.

    This is the KOReader port of the original EPUB.js experiment.

    The original web version:
      - parsed EPUB DOM text nodes,
      - used Intl.Segmenter for sentence detection,
      - injected <span> elements around sentences,
      - and styled those spans with CSS borders.

    This version deliberately does NOT modify the EPUB.

    Instead, it uses KOReader's native document/XPointer machinery
    to:

      1. Locate the visible page.
      2. Find sentence boundaries.
      3. Represent sentences as XPointer ranges.
      4. Test KOReader's native selection/highlight renderer.

    The current prototype highlights one sentence at a time. This is
    intentional: before attempting a custom renderer capable of
    displaying many independently styled sentence boxes, we first
    want to verify that KOReader's sentence/XPointer machinery gives
    us reliable ranges.

    Future work:
      - enumerate all sentences on the visible page,
      - determine their screen bounding boxes,
      - experiment with multiple simultaneous visual marks,
      - reproduce the solid/dashed/thick sentence-box treatment
        from the original web experiment.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")


-- Bump this on every change so it's easy to confirm, from the device
-- itself, that a freshly copied-over main.lua actually took effect
-- rather than a stale cached copy still being loaded.
local PLUGIN_VERSION = "2026-08-16.8"


local SentenceExperiment = WidgetContainer:extend{
    name = "sentenceexperiment",

    -- This plugin only makes sense inside the reader.
    is_doc_only = false,

    enabled = false,

    -- Safety limit while experimenting with sentence enumeration.
    max_sentences_per_page = 100,

    -- Safety limit for the word-by-word sentence-boundary walk below,
    -- in case a paragraph has no recognizable sentence-ending
    -- punctuation for an unexpectedly long stretch.
    max_words_per_sentence = 80,
}


------------------------------------------------------------
-- Initialization
------------------------------------------------------------

function SentenceExperiment:init()
    logger.info("SentenceExperiment: loaded, version", PLUGIN_VERSION)
    self.ui.menu:registerToMainMenu(self)
end


------------------------------------------------------------
-- Main menu
------------------------------------------------------------

function SentenceExperiment:addToMainMenu(menu_items)
    menu_items.sentence_experiment = {
        text = _("Sentence Experiment") .. " (" .. PLUGIN_VERSION .. ")",

        -- Places this under the document menu's "Typeset" submenu
        -- rather than the general main menu.
        sorting_hint = "typeset",

        sub_item_table = {
            {
                text_func = function()
                    if self.enabled then
                        return _("Sentence marking: ON")
                    else
                        return _("Sentence marking: OFF")
                    end
                end,

                checked_func = function()
                    return self.enabled
                end,

                callback = function()
                    self:toggle()
                end,
            },

            {
                text = _("Test current sentence"),

                enabled_func = function()
                    return self.ui.document ~= nil
                end,

                callback = function()
                    self:testCurrentSentence()
                end,
            },

            {
                text = _("List sentences on page"),

                enabled_func = function()
                    return self.ui.document ~= nil
                end,

                callback = function()
                    self:listCurrentPageSentences()
                end,
            },

            {
                text = _("About"),

                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Sentence Experiment") .. "\n" ..
                            _("Version: ") .. PLUGIN_VERSION .. "\n\n" ..
                            _([[
This experimental plugin explores whether making sentence boundaries visually salient changes the reading experience.

The original prototype was built with EPUB.js and JavaScript. This version uses KOReader's document and XPointer facilities instead of modifying the EPUB.

The current prototype is focused on verifying sentence detection and XPointer ranges before implementing a custom multi-sentence renderer.
]]),
                    })
                end,
            },
        },
    }
end


------------------------------------------------------------
-- Toggle
------------------------------------------------------------

function SentenceExperiment:toggle()
    self.enabled = not self.enabled

    if self.enabled then
        self:markCurrentPage()
    else
        self:clearMarks()
    end
end


------------------------------------------------------------
-- Clear native selection/highlight
------------------------------------------------------------

function SentenceExperiment:clearMarks()
    local view = self.ui.view

    if not view or not view.highlight then
        return
    end

    -- highlight.temp is KOReader's own scratch slot for temporary,
    -- non-persisted highlight boxes (also used e.g. for dictionary
    -- lookup selection previews). Clearing it never touches the
    -- reader's real saved/persisted highlights, which live in a
    -- separate table (highlight.saved) that we never write to.
    view.highlight.temp = {}

    UIManager:setDirty(
        self.ui.view,
        "full"
    )
end


------------------------------------------------------------
-- Get the first visible word on the current page
------------------------------------------------------------

function SentenceExperiment:getCurrentPageStart()
    local document = self.ui.document

    if not document then
        return nil
    end

    local page = document:getCurrentPage()

    if not page then
        return nil
    end

    local page_xp = document:getPageXPointer(page)

    if not page_xp then
        return nil
    end

    -- A page XPointer does not necessarily point directly at the
    -- beginning of a word. But it sometimes DOES -- e.g. a page that
    -- happens to start a new paragraph right at its top. In that
    -- case, calling getNextVisibleWordStart(page_xp) would be wrong:
    -- that call always returns the NEXT word start strictly AFTER
    -- the position given to it, never the word already sitting AT
    -- that position -- so it would skip straight past the page's
    -- true first word (same bug shape as the sentence-chaining fix
    -- in getSentenceFromXPointer, one level up).
    --
    -- So: first check whether page_xp is already usable as a word
    -- start directly, by checking that getNextVisibleWordEnd() can
    -- resolve a word there. Only fall back to searching forward if
    -- that fails, meaning page_xp landed somewhere before any word
    -- (e.g. mid-whitespace or at a block boundary).
    if document:getNextVisibleWordEnd(page_xp) then
        return page_xp
    end

    local word_xp = document:getNextVisibleWordStart(page_xp)

    if word_xp then
        return word_xp
    end

    -- If the page contains no visible word after its page XPointer,
    -- use the page XPointer itself as a fallback.
    return page_xp
end


------------------------------------------------------------
-- Determine whether an XPointer belongs to the current page
------------------------------------------------------------

function SentenceExperiment:isXPointerOnCurrentPage(xp)
    local document = self.ui.document

    if not document or not xp then
        return false
    end

    local current_page = document:getCurrentPage()

    if not current_page then
        return false
    end

    local page = document:getPageFromXPointer(xp)

    return page == current_page
end


------------------------------------------------------------
-- Sentence-boundary heuristics
------------------------------------------------------------

-- Common abbreviations that end in a period but essentially never
-- end a sentence.
local ABBREVIATIONS = {
    ["mr"] = true, ["mrs"] = true, ["ms"] = true, ["mx"] = true,
    ["dr"] = true, ["prof"] = true, ["sr"] = true, ["jr"] = true,
    ["st"] = true, ["ave"] = true, ["blvd"] = true,
    ["vs"] = true, ["etc"] = true, ["eg"] = true, ["ie"] = true,
    ["approx"] = true, ["no"] = true, ["vol"] = true, ["fig"] = true,
    ["al"] = true, ["cf"] = true, ["ca"] = true, ["cap"] = true,
    ["ch"] = true, ["ed"] = true, ["esp"] = true, ["est"] = true,
    ["gen"] = true, ["gov"] = true, ["inc"] = true, ["ltd"] = true,
    ["co"] = true, ["corp"] = true, ["dept"] = true,
    ["min"] = true, ["max"] = true, ["misc"] = true, ["pp"] = true,
    ["univ"] = true, ["am"] = true, ["pm"] = true,
}

-- `word_text` is the word immediately BEFORE the gap being tested,
-- `gap_text` is whatever visible-word XPointers skip over between
-- one word and the next -- punctuation, quote marks, whitespace.
-- KOReader's word-boundary XPointers (getNextVisibleWordStart/End)
-- do not include punctuation as part of a word at all, so the
-- sentence-ending character always shows up in the gap, never in
-- the word text itself.
local function looksLikeSentenceBoundary(word_text, gap_text)
    -- Sentence end: '.', '!' or '?' as the first non-whitespace
    -- character of the gap (quotes/parens may follow it, we don't
    -- need to check those).
    if not gap_text:match("^%s*[%.!?]") then
        return false
    end

    -- Only '.' is ambiguous (abbreviations, decimals, list markers);
    -- '!' and '?' are unambiguous sentence ends.
    if not gap_text:match("^%s*%.") then
        return true
    end

    if not word_text or word_text == "" then
        return true
    end

    -- Digits immediately before a period: decimal number, list
    -- marker, or section number -- not a sentence end.
    if word_text:match("^%d+$") then
        return false
    end

    -- Known abbreviation immediately before the period.
    local last_word = word_text:match("(%a+)$")

    if last_word and ABBREVIATIONS[last_word:lower()] then
        return false
    end

    return true
end


------------------------------------------------------------
-- Find one sentence beginning at or after an XPointer
------------------------------------------------------------

function SentenceExperiment:getSentenceFromXPointer(start_xp)
    local document = self.ui.document

    if not document or not start_xp then
        return nil, nil
    end

    -- NOTE: We deliberately do NOT use document:extendXPointersToSentenceSegment()
    -- here. On the versions/documents this was tested against, it reliably
    -- returns nil even for plain mid-paragraph xpointers produced moments
    -- earlier by getNextVisibleWordStart/getNextVisibleWordEnd on the same
    -- document (see cre.cpp: it bails out whenever either xpointer string
    -- fails to re-resolve via createXPointer(), which appears to happen for
    -- word-boundary xpointers in some DOM/version combinations). Rather than
    -- depend on that engine call, we detect sentence boundaries ourselves.
    --
    -- Important detail: getNextVisibleWordStart/End treat punctuation as
    -- NOT part of a word. A word's end XPointer lands right after its
    -- last letter, before any trailing period/comma/quote, and the next
    -- word's start XPointer lands after skipping over all of that. That
    -- means sentence-ending punctuation only ever shows up in the GAP
    -- between one word's end and the next word's start -- never inside
    -- the word text itself. So each iteration below inspects that gap,
    -- not the accumulated word text.
    local word_start = start_xp
    local word_end = document:getNextVisibleWordEnd(word_start)

    if not word_end then
        return nil, nil
    end

    local sentence_end = word_end

    -- Where the NEXT sentence should start from. When we break out
    -- because we found a real boundary, this is next_word_start --
    -- which is already a word-start XPointer, so the caller must use
    -- it directly rather than calling getNextVisibleWordStart() on
    -- it again (that would skip straight past it to the word after,
    -- silently eating the first word of every following sentence).
    -- When we break for any other reason (end of page, safety cap),
    -- this stays nil and the caller falls back to searching forward
    -- from sentence_end itself.
    local resume_from = nil

    for _ = 1, self.max_words_per_sentence do
        local word_text = document:getTextFromXPointers(word_start, word_end)

        local next_word_start = document:getNextVisibleWordStart(word_end)

        if not next_word_start then
            -- No more words (end of page/document) -- treat the
            -- current word's end as the sentence end.
            sentence_end = word_end
            break
        end

        local gap_text = document:getTextFromXPointers(word_end, next_word_start) or ""

        if looksLikeSentenceBoundary(word_text, gap_text) then
            -- Include the gap itself (punctuation, closing quote)
            -- in the sentence range, up to the start of the next word.
            sentence_end = next_word_start
            resume_from = next_word_start
            break
        end

        local next_word_end = document:getNextVisibleWordEnd(next_word_start)

        if not next_word_end then
            sentence_end = word_end
            break
        end

        -- Protect against a non-advancing XPointer.
        local advance_comparison = document:compareXPointers(word_end, next_word_end)

        if advance_comparison == nil or advance_comparison <= 0 then
            sentence_end = word_end
            break
        end

        word_start = next_word_start
        word_end = next_word_end
        sentence_end = word_end
    end

    -- compareXPointers(a, b):
    --   1  -> b is after a
    --   0  -> same
    --  -1  -> b is before a
    -- nil  -> invalid XPointer
    local comparison = document:compareXPointers(start_xp, sentence_end)

    if comparison == nil or comparison <= 0 then
        return nil, nil, nil
    end

    return start_xp, sentence_end, resume_from
end


------------------------------------------------------------
-- Enumerate sentences on the current page
------------------------------------------------------------

function SentenceExperiment:getCurrentPageSentences()
    local document = self.ui.document

    if not document then
        return {}
    end

    local first_xp = self:getCurrentPageStart()

    if not first_xp then
        return {}
    end

    local sentences = {}
    local current_xp = first_xp

    for i = 1, self.max_sentences_per_page do

        -- Stop once we've moved beyond the current page.
        if not self:isXPointerOnCurrentPage(current_xp) then
            break
        end

        local sentence_start, sentence_end, resume_from =
            self:getSentenceFromXPointer(current_xp)

        if not sentence_start or not sentence_end then
            break
        end

        -- If sentence_start has somehow moved outside the page,
        -- don't include it in this page's result.
        if not self:isXPointerOnCurrentPage(sentence_start) then
            break
        end

        local sentence_text =
            document:getTextFromXPointers(
                sentence_start,
                sentence_end
            )

        if not sentence_text or sentence_text == "" then
            break
        end

        table.insert(sentences, {
            index = i,
            start_xp = sentence_start,
            end_xp = sentence_end,
            text = sentence_text,
        })

        logger.dbg(
            "SentenceExperiment: sentence",
            i,
            sentence_start,
            sentence_end,
            sentence_text
        )

        -- Move forward from the end of the sentence. resume_from,
        -- when set, is already the correct word-start XPointer for
        -- the next sentence -- reuse it directly instead of calling
        -- getNextVisibleWordStart(sentence_end) again, which would
        -- skip past it (see the comment in getSentenceFromXPointer).
        local next_xp = resume_from

        if not next_xp then
            next_xp = document:getNextVisibleWordStart(sentence_end)
        end

        if not next_xp then
            break
        end

        -- Protect against a non-advancing XPointer.
        local next_comparison =
            document:compareXPointers(
                current_xp,
                next_xp
            )

        if next_comparison == nil or next_comparison <= 0 then
            logger.warn(
                "SentenceExperiment: XPointer did not advance",
                current_xp,
                next_xp,
                next_comparison
            )

            break
        end

        -- If the next position is not on the current page,
        -- enumeration is complete.
        if not self:isXPointerOnCurrentPage(next_xp) then
            break
        end

        current_xp = next_xp
    end

    if #sentences >= self.max_sentences_per_page then
        logger.warn(
            "SentenceExperiment: reached sentence safety limit",
            self.max_sentences_per_page
        )
    end

    return sentences
end


------------------------------------------------------------
-- Highlight alternating sentences on the current page
------------------------------------------------------------

function SentenceExperiment:markCurrentPage()
    local document = self.ui.document
    local view = self.ui.view

    if not document or not view or not view.highlight then
        return
    end

    local sentences = self:getCurrentPageSentences()

    if #sentences == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Couldn't find any sentences on this page."),
        })

        return
    end

    local page = document:getCurrentPage()
    local boxes = {}

    -- Alternate: highlight sentence 1, skip 2, highlight 3, skip 4, ...
    -- We use view.highlight.temp rather than native selection
    -- rendering, because that only ever supports one active selection
    -- at a time -- it can't represent several independent highlighted
    -- regions on the same page. highlight.temp is KOReader's own
    -- scratch slot for temporary, non-persisted highlight boxes and
    -- happily accepts a combined list from several separate ranges.
    --
    -- We use getScreenBoxesFromPositions(pos0, pos1) rather than
    -- getPageBoxesFromPositions(page, pos0, pos1): the latter needs a
    -- page number in whatever internal convention the engine expects
    -- for that specific call, which we were never able to fully pin
    -- down, and a mismatch there can crash the whole app natively
    -- (no catchable Lua error, no traceback) rather than failing
    -- gracefully. getScreenBoxesFromPositions needs no page number at
    -- all, sidestepping that risk entirely.
    --
    -- It's also a call KOReader's own maintainers have noted CAN
    -- throw ("attempt to get length of local 'word_boxes' (a nil
    -- value)") for ranges it can't resolve boxes for, so we wrap it
    -- in pcall and just skip that sentence's boxes on failure rather
    -- than let it take the app down.
    for _, sentence in ipairs(sentences) do
        if sentence.index % 2 == 1 then
            local ok, sentence_boxes = pcall(
                document.getScreenBoxesFromPositions,
                document,
                sentence.start_xp,
                sentence.end_xp
            )

            if not ok then
                logger.warn(
                    "SentenceExperiment: getScreenBoxesFromPositions failed for sentence",
                    sentence.index,
                    sentence_boxes
                )
            elseif sentence_boxes then
                for _, box in ipairs(sentence_boxes) do
                    table.insert(boxes, box)
                end
            end
        end
    end

    view.highlight.temp[page] = boxes

    logger.dbg(
        "SentenceExperiment: marked",
        #boxes,
        "boxes across",
        #sentences,
        "sentences on page",
        page
    )

    UIManager:setDirty(
        self.ui.view,
        "ui"
    )
end


------------------------------------------------------------
-- Test the sentence at the current reading position
------------------------------------------------------------

function SentenceExperiment:testCurrentSentence()
    local document = self.ui.document

    if not document then
        return
    end

    local xp = document:getXPointer()

    if not xp then
        UIManager:show(InfoMessage:new{
            text = _("Couldn't obtain the current text position."),
        })

        return
    end

    local sentence_start, sentence_end =
        self:getSentenceFromXPointer(xp)

    if not sentence_start or not sentence_end then
        UIManager:show(InfoMessage:new{
            text = _("Couldn't determine the current sentence."),
        })

        return
    end

    local sentence =
        document:getTextFromXPointers(
            sentence_start,
            sentence_end
        )

    if not sentence or sentence == "" then
        UIManager:show(InfoMessage:new{
            text = _("Sentence detection returned no text."),
        })

        return
    end

    logger.dbg(
        "SentenceExperiment: current sentence",
        sentence_start,
        sentence_end,
        sentence
    )

    UIManager:show(InfoMessage:new{
        text =
            _("Current sentence:\n\n") ..
            sentence,
    })
end


------------------------------------------------------------
-- List sentences on the current page
------------------------------------------------------------

function SentenceExperiment:listCurrentPageSentences()
    local sentences = self:getCurrentPageSentences()

    if #sentences == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Couldn't find any sentences on this page."),
        })

        return
    end

    local lines = {
        _("Sentences found: ") .. #sentences,
        "",
    }

    for _, sentence in ipairs(sentences) do
        table.insert(
            lines,
            string.format(
                "%d. %s",
                sentence.index,
                sentence.text
            )
        )
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end


------------------------------------------------------------
-- Reader lifecycle
------------------------------------------------------------

function SentenceExperiment:onPageUpdate()
    if not self.enabled then
        return
    end

    -- A page update can happen for reasons other than a simple
    -- page turn, so keep this operation deliberately small.
    self:clearMarks()
    self:markCurrentPage()
end


------------------------------------------------------------
-- Cleanup
------------------------------------------------------------

function SentenceExperiment:onCloseDocument()
    self:clearMarks()
end


return SentenceExperiment
