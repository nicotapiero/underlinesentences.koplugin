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


local SentenceExperiment = WidgetContainer:extend{
    name = "sentenceexperiment",

    -- This plugin only makes sense inside the reader.
    is_doc_only = false,

    enabled = false,

    -- Safety limit while experimenting with sentence enumeration.
    max_sentences_per_page = 100,
}


------------------------------------------------------------
-- Initialization
------------------------------------------------------------

function SentenceExperiment:init()
    self.ui.menu:registerToMainMenu(self)
end


------------------------------------------------------------
-- Main menu
------------------------------------------------------------

function SentenceExperiment:addToMainMenu(menu_items)
    menu_items.sentence_experiment = {
        text = _("Sentence Experiment"),

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
                        text = _([[
Sentence Experiment

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
    local document = self.ui.document

    if not document then
        return
    end

    -- highlightXPointer(nil) clears the current document highlight(s).
    pcall(function()
        document:highlightXPointer(nil)
    end)

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
    -- beginning of a word. Move forward to the first visible word.
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
-- Find one sentence beginning at or after an XPointer
------------------------------------------------------------

function SentenceExperiment:getSentenceFromXPointer(start_xp)
    local document = self.ui.document

    if not document or not start_xp then
        return nil, nil
    end

    -- Give the document engine a small range beginning at the
    -- requested position.
    local probe_end = document:getNextVisibleWordEnd(start_xp)

    if not probe_end then
        return nil, nil
    end

    -- Expand the range to sentence boundaries recognized by
    -- the document engine.
    local sentence_start, sentence_end =
        document:extendXPointersToSentenceSegment(
            start_xp,
            probe_end
        )

    if not sentence_start or not sentence_end then
        return nil, nil
    end

    -- compareXPointers(a, b):
    --   1  -> b is after a
    --   0  -> same
    --  -1  -> b is before a
    -- nil  -> invalid XPointer
    local comparison = document:compareXPointers(
        sentence_start,
        sentence_end
    )

    if comparison == nil or comparison <= 0 then
        return nil, nil
    end

    return sentence_start, sentence_end
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

        local sentence_start, sentence_end =
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

        -- Move forward from the end of the sentence.
        local next_xp =
            document:getNextVisibleWordStart(sentence_end)

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
-- Highlight the first sentence on the current page
------------------------------------------------------------

function SentenceExperiment:markCurrentPage()
    local document = self.ui.document

    if not document then
        return
    end

    local sentences = self:getCurrentPageSentences()

    if #sentences == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Couldn't find any sentences on this page."),
        })

        return
    end

    local sentence = sentences[1]

    -- Native KOReader selection/highlight rendering.
    --
    -- This is deliberately limited to one sentence for now.
    document:getTextFromXPointers(
        sentence.start_xp,
        sentence.end_xp,
        true
    )

    logger.dbg(
        "SentenceExperiment: marked sentence",
        sentence.index,
        sentence.text
    )

    UIManager:setDirty(
        self.ui.view,
        "full"
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
