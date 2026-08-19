--[[
    Sentence Experiment - Continuous Outline For Every Sentence

    Version 2026-08-18.2

    This version:

      - Finds every sentence on the current page.
      - Uses KOReader XPointers for sentence boundaries.
      - Gets the screen geometry for each sentence independently.
      - Groups each sentence's screen boxes into visual lines.
      - Builds one continuous stepped outline around each sentence.
      - Draws all sentence outlines simultaneously.
      - Splits the gap between same-row adjacent sentences at
        its midpoint, instead of snapping it to the start of
        the next sentence.
      - Recognizes sentence endings like ")." or "." that are
        preceded by a closing bracket or quote in the gap.

    A multi-line sentence is NOT enclosed in one large bounding
    rectangle. Its outline follows the actual left/right edges of
    each visual line.

    Example:

        ┌──────────────────────────────────┐
        │ This is a sentence that wraps    │
        │ onto another line of the page.   │
        └──────────────────────────────────┘

    Internally this is represented as a stepped polygon following
    the union of the individual line rectangles.

    The EPUB/document itself is never modified.
--]]


local WidgetContainer =
    require("ui/widget/container/widgetcontainer")

local InfoMessage =
    require("ui/widget/infomessage")

local SpinWidget =
    require("ui/widget/spinwidget")

local UIManager =
    require("ui/uimanager")

local ReaderView =
    require("apps/reader/modules/readerview")

local Device =
    require("device")

local Blitbuffer =
    require("ffi/blitbuffer")

local logger =
    require("logger")

local _ =
    require("gettext")


local Screen =
    Device.screen


local PLUGIN_VERSION =
    "2026-08-18.2"


local DEFAULT_OUTLINE_THICKNESS =
    2

local OUTLINE_THICKNESS_SETTING =
    "sentence_experiment_outline_thickness"


------------------------------------------------------------
-- Plugin
------------------------------------------------------------

local SentenceExperiment =
    WidgetContainer:extend{

    name = "sentenceexperiment",

    is_doc_only = false,

    enabled = false,

    --------------------------------------------------------
    -- Safety limit for sentence enumeration.
    --------------------------------------------------------

    max_sentences_per_page = 100,

    --------------------------------------------------------
    -- Safety limit for the word-by-word sentence walk.
    --------------------------------------------------------

    max_words_per_sentence = 80,
}


------------------------------------------------------------
-- Initialization
------------------------------------------------------------

function SentenceExperiment:init()

    logger.info(
        "SentenceExperiment loaded",
        PLUGIN_VERSION
    )


    self.ui.menu:registerToMainMenu(self)


    --------------------------------------------------------
    -- Outline thickness, persisted across sessions.
    --------------------------------------------------------

    self.outline_thickness =
        G_reader_settings:readSetting(
            OUTLINE_THICKNESS_SETTING
        )
        or DEFAULT_OUTLINE_THICKNESS


    --------------------------------------------------------
    -- Each entry contains:
    --
    -- {
    --     index = ...,
    --     start_xp = ...,
    --     end_xp = ...,
    --     text = ...,
    --     boxes = ...,
    -- }
    --------------------------------------------------------

    self.test_sentences = nil


    --------------------------------------------------------
    -- Install drawing hook once.
    --------------------------------------------------------

    if not SentenceExperiment.paint_hook_installed then

        local original_paintTo =
            ReaderView.paintTo


        ReaderView.paintTo =
            function(view, bb, x, y)

                ------------------------------------------------
                -- Normal KOReader rendering first.
                ------------------------------------------------

                original_paintTo(
                    view,
                    bb,
                    x,
                    y
                )


                ------------------------------------------------
                -- Only draw on the actual screen.
                ------------------------------------------------

                if bb ~= Screen.bb then
                    return
                end


                local plugin =
                    SentenceExperiment.instance


                if not plugin then
                    return
                end


                if not plugin.enabled then
                    return
                end


                local sentences =
                    plugin.test_sentences


                if not sentences then
                    return
                end


                ------------------------------------------------
                -- Draw every sentence independently.
                ------------------------------------------------

                for _, sentence in ipairs(sentences) do

                    if sentence.lines
                        and #sentence.lines > 0 then

                        plugin:drawSentenceOutline(
                            bb,
                            sentence.lines
                        )
                    end
                end
            end


        SentenceExperiment.paint_hook_installed =
            true
    end


    SentenceExperiment.instance =
        self
end


------------------------------------------------------------
-- Main menu
------------------------------------------------------------

function SentenceExperiment:addToMainMenu(menu_items)

    menu_items.sentence_experiment = {

        text =
            _("Sentence Experiment")
            .. " ("
            .. PLUGIN_VERSION
            .. ")",

        sorting_hint = "typeset",

        sub_item_table = {

            {
                text_func = function()

                    if self.enabled then
                        return _("Sentence outlines: ON")
                    else
                        return _("Sentence outlines: OFF")
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
                text =
                    _("Find sentence outlines"),

                enabled_func = function()
                    return self.ui.document ~= nil
                end,

                callback = function()
                    self:markCurrentPage()
                end,
            },


            {
                text =
                    _("List sentences on page"),

                enabled_func = function()
                    return self.ui.document ~= nil
                end,

                callback = function()
                    self:listCurrentPageSentences()
                end,
            },


            {
                text_func = function()

                    return _("Outline thickness: ")
                        .. self.outline_thickness
                        .. " px"
                end,

                keep_menu_open = true,

                callback = function()
                    self:showOutlineThicknessDialog()
                end,
            },
        },
    }
end


------------------------------------------------------------
-- Outline thickness setting
------------------------------------------------------------

function SentenceExperiment:showOutlineThicknessDialog()

    local dialog


    dialog =
        SpinWidget:new{

            value =
                self.outline_thickness,

            value_min = 1,

            value_max = 8,

            value_step = 1,

            value_hold_step = 2,

            title_text =
                _("Outline thickness"),

            text = _(
                "Thickness, in pixels, of the sentence outline."
            ),

            ok_text =
                _("Set"),

            default_value =
                DEFAULT_OUTLINE_THICKNESS,

            callback = function(spin)

                self.outline_thickness =
                    spin.value


                G_reader_settings:saveSetting(
                    OUTLINE_THICKNESS_SETTING,
                    spin.value
                )


                if self.enabled then

                    UIManager:setDirty(
                        self.ui.view,
                        "full"
                    )
                end
            end,
        }


    UIManager:show(dialog)
end


------------------------------------------------------------
-- Toggle
------------------------------------------------------------

function SentenceExperiment:toggle()

    self.enabled =
        not self.enabled


    if self.enabled then

        self:markCurrentPage()

    else

        self.test_sentences = nil

        UIManager:setDirty(
            self.ui.view,
            "full"
        )
    end
end


------------------------------------------------------------
-- Current page start
------------------------------------------------------------

function SentenceExperiment:getCurrentPageStart()

    local document =
        self.ui.document

    if not document then
        return nil
    end


    local page =
        document:getCurrentPage()

    if not page then
        return nil
    end


    local page_xp =
        document:getPageXPointer(page)

    if not page_xp then
        return nil
    end


    --------------------------------------------------------
    -- The page XPointer may itself be a word start.
    --------------------------------------------------------

    if document:getNextVisibleWordEnd(
        page_xp
    ) then

        return page_xp
    end


    local word_xp =
        document:getNextVisibleWordStart(
            page_xp
        )


    if word_xp then
        return word_xp
    end


    return page_xp
end


------------------------------------------------------------
-- Determine whether an XPointer belongs to current page
------------------------------------------------------------

function SentenceExperiment:isXPointerOnCurrentPage(xp)

    local document =
        self.ui.document

    if not document
        or not xp then

        return false
    end


    local current_page =
        document:getCurrentPage()

    if not current_page then
        return false
    end


    local page =
        document:getPageFromXPointer(xp)


    return page == current_page
end


------------------------------------------------------------
-- Sentence abbreviations
------------------------------------------------------------

local ABBREVIATIONS = {

    ["mr"] = true,
    ["mrs"] = true,
    ["ms"] = true,
    ["mx"] = true,

    ["dr"] = true,
    ["prof"] = true,
    ["sr"] = true,
    ["jr"] = true,

    ["st"] = true,
    ["ave"] = true,
    ["blvd"] = true,

    ["vs"] = true,
    ["etc"] = true,
    ["eg"] = true,
    ["ie"] = true,

    ["approx"] = true,
    ["no"] = true,
    ["vol"] = true,
    ["fig"] = true,

    ["al"] = true,
    ["cf"] = true,
    ["ca"] = true,
    ["cap"] = true,

    ["ch"] = true,
    ["ed"] = true,
    ["esp"] = true,
    ["est"] = true,

    ["gen"] = true,
    ["gov"] = true,

    ["inc"] = true,
    ["ltd"] = true,
    ["co"] = true,
    ["corp"] = true,

    ["dept"] = true,

    ["min"] = true,
    ["max"] = true,

    ["misc"] = true,
    ["pp"] = true,

    ["univ"] = true,

    ["am"] = true,
    ["pm"] = true,
}


------------------------------------------------------------
-- Sentence boundary
------------------------------------------------------------

local function looksLikeSentenceBoundary(
    word_text,
    gap_text
)

    if not gap_text then
        return false
    end


    --------------------------------------------------------
    -- Sentence-ending punctuation must be the first
    -- non-whitespace character in the gap, but closing
    -- brackets/quotes can sit in front of it -- "(see
    -- below)." or he said "stop." -- so skip over any of
    -- those first, then look for the actual mark.
    --------------------------------------------------------

    local mark =
        gap_text:match(
            "^%s*[%)%]%}\"'”’»›]*([%.!?])"
        )

    if not mark then
        return false
    end


    --------------------------------------------------------
    -- ! and ? are unambiguous.
    --------------------------------------------------------

    if mark ~= "." then
        return true
    end


    if not word_text
        or word_text == "" then

        return true
    end


    --------------------------------------------------------
    -- Numeric period.
    --------------------------------------------------------

    if word_text:match("^%d+$") then
        return false
    end


    --------------------------------------------------------
    -- Abbreviation.
    --------------------------------------------------------

    local last_word =
        word_text:match("(%a+)$")


    if last_word
        and ABBREVIATIONS[
            last_word:lower()
        ] then

        return false
    end


    return true
end


------------------------------------------------------------
-- Find one sentence beginning at an XPointer
------------------------------------------------------------

function SentenceExperiment:getSentenceFromXPointer(
    start_xp
)

    local document =
        self.ui.document

    if not document
        or not start_xp then

        return nil, nil
    end


    local word_start =
        start_xp


    local word_end =
        document:getNextVisibleWordEnd(
            word_start
        )


    if not word_end then
        return nil, nil
    end


    local sentence_end =
        word_end


    --------------------------------------------------------
    -- If we actually encountered a sentence boundary,
    -- this contains the correct XPointer at which the next
    -- sentence begins.
    --------------------------------------------------------

    local resume_from =
        nil


    for _ = 1,
        self.max_words_per_sentence do


        local word_text =
            document:getTextFromXPointers(
                word_start,
                word_end
            )


        local next_word_start =
            document:getNextVisibleWordStart(
                word_end
            )


        if not next_word_start then

            sentence_end =
                word_end

            break
        end


        local gap_text =
            document:getTextFromXPointers(
                word_end,
                next_word_start
            ) or ""


        ----------------------------------------------------
        -- Sentence boundary found.
        ----------------------------------------------------

        if looksLikeSentenceBoundary(
            word_text,
            gap_text
        ) then

            sentence_end =
                next_word_start

            resume_from =
                next_word_start

            break
        end


        local next_word_end =
            document:getNextVisibleWordEnd(
                next_word_start
            )


        if not next_word_end then

            sentence_end =
                word_end

            break
        end


        ----------------------------------------------------
        -- Protect against non-advancing XPointers.
        ----------------------------------------------------

        local comparison =
            document:compareXPointers(
                word_end,
                next_word_end
            )


        if comparison == nil
            or comparison <= 0 then

            sentence_end =
                word_end

            break
        end


        word_start =
            next_word_start

        word_end =
            next_word_end

        sentence_end =
            word_end
    end


    --------------------------------------------------------
    -- Verify the sentence actually advances.
    --------------------------------------------------------

    local comparison =
        document:compareXPointers(
            start_xp,
            sentence_end
        )


    if comparison == nil
        or comparison <= 0 then

        return nil, nil, nil
    end


    return
        start_xp,
        sentence_end,
        resume_from
end


------------------------------------------------------------
-- Enumerate every sentence on current page
------------------------------------------------------------

function SentenceExperiment:getCurrentPageSentences()

    local document =
        self.ui.document

    if not document then
        return {}
    end


    local first_xp =
        self:getCurrentPageStart()

    if not first_xp then
        return {}
    end


    local sentences = {}


    local current_xp =
        first_xp


    for i = 1,
        self.max_sentences_per_page do


        ----------------------------------------------------
        -- Stop once we leave the current page.
        ----------------------------------------------------

        if not self:isXPointerOnCurrentPage(
            current_xp
        ) then

            break
        end


        local sentence_start,
            sentence_end,
            resume_from =

            self:getSentenceFromXPointer(
                current_xp
            )


        if not sentence_start
            or not sentence_end then

            break
        end


        ----------------------------------------------------
        -- The sentence must begin on this page.
        ----------------------------------------------------

        if not self:isXPointerOnCurrentPage(
            sentence_start
        ) then

            break
        end


        local sentence_text =
            document:getTextFromXPointers(
                sentence_start,
                sentence_end
            )


        if not sentence_text
            or sentence_text == "" then

            break
        end


        table.insert(
            sentences,
            {
                index = i,

                start_xp =
                    sentence_start,

                end_xp =
                    sentence_end,

                text =
                    sentence_text,

                boxes = {},
            }
        )


        logger.dbg(
            "SentenceExperiment: sentence",
            i,
            sentence_start,
            sentence_end,
            sentence_text
        )


        ----------------------------------------------------
        -- Find next sentence.
        --
        -- resume_from is already the start of the next word
        -- when we stopped on punctuation.
        ----------------------------------------------------

        local next_xp =
            resume_from


        if not next_xp then

            next_xp =
                document:getNextVisibleWordStart(
                    sentence_end
                )
        end


        if not next_xp then
            break
        end


        ----------------------------------------------------
        -- Protect against non-advancing XPointer.
        ----------------------------------------------------

        local next_comparison =
            document:compareXPointers(
                current_xp,
                next_xp
            )


        if next_comparison == nil
            or next_comparison <= 0 then

            logger.warn(
                "SentenceExperiment: XPointer did not advance",
                current_xp,
                next_xp,
                next_comparison
            )

            break
        end


        ----------------------------------------------------
        -- Once the next sentence begins on another page,
        -- we're done with this page.
        ----------------------------------------------------

        if not self:isXPointerOnCurrentPage(
            next_xp
        ) then

            break
        end


        current_xp =
            next_xp
    end


    if #sentences >=
        self.max_sentences_per_page then

        logger.warn(
            "SentenceExperiment: reached sentence safety limit",
            self.max_sentences_per_page
        )
    end


    return sentences
end


------------------------------------------------------------
-- Group raw screen boxes into visual lines
------------------------------------------------------------

function SentenceExperiment:getLineBoxes(boxes)

    local lines = {}


    for _, box in ipairs(boxes) do

        local x =
            tonumber(box.x)

        local y =
            tonumber(box.y)

        local w =
            tonumber(box.w)

        local h =
            tonumber(box.h)


        if x and y and w and h
            and w > 0
            and h > 0 then


            local center_y =
                y + h / 2


            local found_line =
                nil


            ------------------------------------------------
            -- Find an existing visual line.
            ------------------------------------------------

            for _, line in ipairs(lines) do

                local line_center =
                    line.y + line.h / 2


                local tolerance =
                    math.min(
                        h,
                        line.h
                    ) * 0.50


                if math.abs(
                    center_y - line_center
                ) <= tolerance then

                    found_line =
                        line

                    break
                end
            end


            ------------------------------------------------
            -- Add to existing line.
            ------------------------------------------------

            if found_line then

                local old_right =
                    found_line.x
                    + found_line.w

                local old_bottom =
                    found_line.y
                    + found_line.h


                local new_right =
                    math.max(
                        old_right,
                        x + w
                    )

                local new_bottom =
                    math.max(
                        old_bottom,
                        y + h
                    )


                found_line.x =
                    math.min(
                        found_line.x,
                        x
                    )

                found_line.y =
                    math.min(
                        found_line.y,
                        y
                    )

                found_line.w =
                    new_right
                    - found_line.x

                found_line.h =
                    new_bottom
                    - found_line.y


            else

                ------------------------------------------------
                -- New visual line.
                ------------------------------------------------

                table.insert(
                    lines,
                    {
                        x = x,
                        y = y,
                        w = w,
                        h = h,
                    }
                )
            end
        end
    end


    --------------------------------------------------------
    -- Sort top-to-bottom.
    --------------------------------------------------------

    table.sort(
        lines,
        function(a, b)

            if a.y == b.y then
                return a.x < b.x
            end

            return a.y < b.y
        end
    )


    return lines
end


------------------------------------------------------------
-- Decide whether two line boxes sit on the same visual row
------------------------------------------------------------

local function onSameVisualRow(
    a,
    b
)

    if not a or not b then
        return false
    end


    local a_center =
        a.y + a.h / 2

    local b_center =
        b.y + b.h / 2


    local tolerance =
        math.min(
            a.h,
            b.h
        ) * 0.50


    return math.abs(
        a_center - b_center
    ) <= tolerance
end


------------------------------------------------------------
-- Merge touching sentence boundaries
--
-- When sentence N ends on the same visual row where sentence
-- N+1 begins, there's a small gap between them on screen: the
-- word-space, plus whatever trailing/leading padding the
-- renderer put on each box. Rather than snapping the seam to
-- either sentence's edge, it's split down the middle. Sentence
-- N's box is stretched right and sentence N+1's box is pulled
-- left to meet at that midpoint. The two outlines then share
-- a single seam there instead of drawing two close, separate
-- lines, and neither sentence visually "owns" the whole gap.
--
-- Only the shared boundary's row is touched. Every other
-- edge of every sentence is left as the actual document
-- geometry produced.
------------------------------------------------------------

function SentenceExperiment:linkAdjacentSentenceBoundaries(
    sentences
)

    if not sentences then
        return
    end


    for i = 2, #sentences do

        local previous =
            sentences[i - 1]

        local current =
            sentences[i]


        if previous.lines
            and current.lines
            and #previous.lines > 0
            and #current.lines > 0 then

            local prev_last =
                previous.lines[
                    #previous.lines
                ]

            local cur_first =
                current.lines[1]


            if onSameVisualRow(
                prev_last,
                cur_first
            ) then

                local prev_right =
                    prev_last.x
                    + prev_last.w

                local cur_left =
                    cur_first.x


                ------------------------------------------------
                -- Only act if there's an actual gap between the
                -- two boxes (the word-space). If they already
                -- touch, overlap, or something unusual put the
                -- previous box further right than expected,
                -- leave both boxes alone rather than shrinking
                -- or flipping either one.
                ------------------------------------------------

                if cur_left > prev_right then

                    local shared_x =
                        prev_right
                        + (cur_left - prev_right)
                        / 2


                    prev_last.w =
                        shared_x
                        - prev_last.x

                    cur_first.w =
                        cur_first.w
                        + (cur_first.x - shared_x)

                    cur_first.x =
                        shared_x
                end
            end
        end
    end
end


------------------------------------------------------------
-- Add a point without creating consecutive duplicates
------------------------------------------------------------

local function addPoint(
    points,
    x,
    y
)

    local previous =
        points[#points]


    if previous
        and previous.x == x
        and previous.y == y then

        return
    end


    table.insert(
        points,
        {
            x = x,
            y = y,
        }
    )
end


------------------------------------------------------------
-- Build stepped outline around line rectangles
------------------------------------------------------------

function SentenceExperiment:buildSentenceOutline(
    lines
)

    local points = {}


    if not lines
        or #lines == 0 then

        return points
    end


    --------------------------------------------------------
    -- Single-line sentence.
    --------------------------------------------------------

    if #lines == 1 then

        local line =
            lines[1]


        addPoint(
            points,
            line.x,
            line.y
        )


        addPoint(
            points,
            line.x + line.w,
            line.y
        )


        addPoint(
            points,
            line.x + line.w,
            line.y + line.h
        )


        addPoint(
            points,
            line.x,
            line.y + line.h
        )


        return points
    end


    --------------------------------------------------------
    -- Start at top-left of first line.
    --------------------------------------------------------

    local first =
        lines[1]


    addPoint(
        points,
        first.x,
        first.y
    )


    --------------------------------------------------------
    -- Top edge of first line.
    --------------------------------------------------------

    addPoint(
        points,
        first.x + first.w,
        first.y
    )


    --------------------------------------------------------
    -- RIGHT SIDE
    --------------------------------------------------------

    for i = 1, #lines do

        local current =
            lines[i]


        local current_right =
            current.x + current.w


        local current_bottom =
            current.y + current.h


        ----------------------------------------------------
        -- Down to bottom of current line.
        ----------------------------------------------------

        addPoint(
            points,
            current_right,
            current_bottom
        )


        local next =
            lines[i + 1]


        if next then

            local next_right =
                next.x + next.w


            ------------------------------------------------
            -- Step horizontally to next line's right edge.
            ------------------------------------------------

            addPoint(
                points,
                next_right,
                current_bottom
            )
        end
    end


    --------------------------------------------------------
    -- Bottom edge of final line.
    --------------------------------------------------------

    local last =
        lines[#lines]


    addPoint(
        points,
        last.x,
        last.y + last.h
    )


    --------------------------------------------------------
    -- LEFT SIDE, walking upward.
    --------------------------------------------------------

    for i = #lines, 1, -1 do

        local current =
            lines[i]


        ----------------------------------------------------
        -- Up to top of current line.
        ----------------------------------------------------

        addPoint(
            points,
            current.x,
            current.y
        )


        local previous =
            lines[i - 1]


        if previous then

            ------------------------------------------------
            -- Step horizontally to previous line's left
            -- edge.
            ------------------------------------------------

            addPoint(
                points,
                previous.x,
                current.y
            )
        end
    end


    return points
end


------------------------------------------------------------
-- Draw one horizontal, vertical, or fallback diagonal line
------------------------------------------------------------

function SentenceExperiment:drawLine(
    bb,
    x1,
    y1,
    x2,
    y2,
    thickness
)

    x1 =
        math.floor(x1 + 0.5)

    y1 =
        math.floor(y1 + 0.5)

    x2 =
        math.floor(x2 + 0.5)

    y2 =
        math.floor(y2 + 0.5)


    if x1 == x2
        and y1 == y2 then

        return
    end


    --------------------------------------------------------
    -- Horizontal.
    --------------------------------------------------------

    if y1 == y2 then

        local x =
            math.min(
                x1,
                x2
            )


        local w =
            math.abs(
                x2 - x1
            ) + 1


        bb:paintRect(
            x,
            y1,
            w,
            thickness,
            Blitbuffer.COLOR_BLACK
        )

        return
    end


    --------------------------------------------------------
    -- Vertical.
    --------------------------------------------------------

    if x1 == x2 then

        local y =
            math.min(
                y1,
                y2
            )


        local h =
            math.abs(
                y2 - y1
            ) + 1


        bb:paintRect(
            x1,
            y,
            thickness,
            h,
            Blitbuffer.COLOR_BLACK
        )

        return
    end


    --------------------------------------------------------
    -- Fallback diagonal.
    --
    -- The normal sentence outline should never need this,
    -- because all outline transitions are horizontal or
    -- vertical.
    --------------------------------------------------------

    local dx =
        x2 - x1

    local dy =
        y2 - y1


    local steps =
        math.max(
            math.abs(dx),
            math.abs(dy)
        )


    if steps <= 0 then
        return
    end


    for i = 0, steps do

        local t =
            i / steps


        local x =
            math.floor(
                x1 + dx * t + 0.5
            )


        local y =
            math.floor(
                y1 + dy * t + 0.5
            )


        bb:paintRect(
            x,
            y,
            thickness,
            thickness,
            Blitbuffer.COLOR_BLACK
        )
    end
end


------------------------------------------------------------
-- Reinforce an outline corner
------------------------------------------------------------

function SentenceExperiment:drawCorner(
    bb,
    x,
    y,
    thickness
)

    local half =
        math.floor(
            thickness / 2
        )


    bb:paintRect(
        math.floor(x) - half,
        math.floor(y) - half,
        thickness,
        thickness,
        Blitbuffer.COLOR_BLACK
    )
end


------------------------------------------------------------
-- Draw one complete sentence outline
------------------------------------------------------------

function SentenceExperiment:drawSentenceOutline(
    bb,
    lines
)

    if not lines
        or #lines == 0 then

        return
    end


    --------------------------------------------------------
    -- Build continuous stepped contour.
    --------------------------------------------------------

    local points =
        self:buildSentenceOutline(
            lines
        )


    if #points < 2 then
        return
    end


    local thickness =
        self.outline_thickness
        or DEFAULT_OUTLINE_THICKNESS


    --------------------------------------------------------
    -- Draw contour.
    --------------------------------------------------------

    for i = 1, #points do

        local a =
            points[i]


        local b =
            points[
                (i % #points) + 1
            ]


        self:drawLine(
            bb,
            a.x,
            a.y,
            b.x,
            b.y,
            thickness
        )
    end


    --------------------------------------------------------
    -- Reinforce corners.
    --------------------------------------------------------

    for _, point in ipairs(points) do

        self:drawCorner(
            bb,
            point.x,
            point.y,
            thickness
        )
    end
end


------------------------------------------------------------
-- Get screen boxes for one sentence
------------------------------------------------------------

function SentenceExperiment:getSentenceBoxes(
    sentence
)

    local document =
        self.ui.document


    if not document
        or not sentence then

        return {}
    end


    --------------------------------------------------------
    -- This is deliberately protected.
    --
    -- KOReader's native geometry function can fail for
    -- certain ranges/documents.
    --------------------------------------------------------

    local ok, boxes =
        pcall(
            document.getScreenBoxesFromPositions,
            document,
            sentence.start_xp,
            sentence.end_xp
        )


    if not ok then

        logger.warn(
            "SentenceExperiment: geometry failed for sentence",
            sentence.index,
            boxes
        )

        return {}
    end


    if not boxes then
        return {}
    end


    --------------------------------------------------------
    -- Copy the native table.
    --------------------------------------------------------

    local copied =
        {}


    for _, box in ipairs(boxes) do

        table.insert(
            copied,
            {
                x = box.x,
                y = box.y,
                w = box.w,
                h = box.h,
            }
        )
    end


    return copied
end


------------------------------------------------------------
-- Find and prepare all sentence outlines on current page
------------------------------------------------------------

function SentenceExperiment:markCurrentPage()

    local document =
        self.ui.document


    if not document then
        return
    end


    --------------------------------------------------------
    -- Enumerate sentences.
    --------------------------------------------------------

    local sentences =
        self:getCurrentPageSentences()


    if #sentences == 0 then

        self.test_sentences =
            nil


        UIManager:show(
            InfoMessage:new{
                text = _(
                    "Couldn't find any sentences on this page."
                ),
            }
        )


        return
    end


    --------------------------------------------------------
    -- Get screen geometry for every sentence.
    --------------------------------------------------------

    for _, sentence in ipairs(sentences) do

        sentence.boxes =
            self:getSentenceBoxes(
                sentence
            )


        if #sentence.boxes > 0 then

            sentence.lines =
                self:getLineBoxes(
                    sentence.boxes
                )


            logger.dbg(
                "SentenceExperiment:",
                "sentence",
                sentence.index,
                "raw boxes",
                #sentence.boxes,
                "visual lines",
                #sentence.lines
            )
        else

            sentence.lines =
                {}


            logger.dbg(
                "SentenceExperiment:",
                "sentence",
                sentence.index,
                "has no screen boxes"
            )
        end
    end


    --------------------------------------------------------
    -- Merge adjacent sentence boundaries.
    --
    -- Where one sentence ends on the same visual line where
    -- the next sentence begins, snap the previous sentence's
    -- box right edge to the next sentence's left edge. This
    -- turns two close, separate lines (with a sliver of gap
    -- for the word-space between sentences) into a single
    -- shared seam.
    --------------------------------------------------------

    self:linkAdjacentSentenceBoundaries(
        sentences
    )


    --------------------------------------------------------
    -- Store the complete page state.
    --------------------------------------------------------

    self.test_sentences =
        sentences


    logger.info(
        "SentenceExperiment:",
        "found",
        #sentences,
        "sentences on current page"
    )


    --------------------------------------------------------
    -- Force redraw.
    --------------------------------------------------------

    UIManager:setDirty(
        self.ui.view,
        "full"
    )
end


------------------------------------------------------------
-- List sentences on current page
------------------------------------------------------------

function SentenceExperiment:listCurrentPageSentences()

    local sentences =
        self:getCurrentPageSentences()


    if #sentences == 0 then

        UIManager:show(
            InfoMessage:new{
                text = _(
                    "Couldn't find any sentences on this page."
                ),
            }
        )

        return
    end


    local lines = {

        _("Sentences found: ")
            .. #sentences,

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


    UIManager:show(
        InfoMessage:new{
            text =
                table.concat(
                    lines,
                    "\n"
                ),
        }
    )
end


------------------------------------------------------------
-- Reader lifecycle
------------------------------------------------------------

function SentenceExperiment:onPageUpdate()

    if not self.enabled then
        return
    end


    --------------------------------------------------------
    -- Re-enumerate everything because the screen geometry
    -- changes with the page.
    --------------------------------------------------------

    self:markCurrentPage()
end


------------------------------------------------------------
-- Document cleanup
------------------------------------------------------------

function SentenceExperiment:onCloseDocument()

    self.test_sentences =
        nil
end


return SentenceExperiment
