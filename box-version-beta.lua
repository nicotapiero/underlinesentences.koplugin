--[[
    Sentence Experiment - Continuous Sentence Outline

    Version 2026-08-16.14

    Finds the first sentence on the current page and draws
    one continuous stepped outline around the actual text
    geometry.

    Multi-line sentences are represented as a single outline
    following the left and right edges of each visual line.

    The outline deliberately does NOT become one large
    bounding rectangle around the entire sentence.
--]]


local WidgetContainer =
    require("ui/widget/container/widgetcontainer")

local InfoMessage =
    require("ui/widget/infomessage")

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
    "2026-08-16.14"


------------------------------------------------------------
-- Plugin
------------------------------------------------------------

local SentenceExperiment =
    WidgetContainer:extend{

    name = "sentenceexperiment",

    is_doc_only = false,

    enabled = false,

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


    self.test_boxes = nil


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
                -- Only draw onto the real screen.
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


                local boxes =
                    plugin.test_boxes


                if not boxes then
                    return
                end


                ------------------------------------------------
                -- Draw one continuous sentence outline.
                ------------------------------------------------

                plugin:drawSentenceOutline(
                    bb,
                    boxes
                )
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
                        return _("Outline test: ON")
                    else
                        return _("Outline test: OFF")
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
                    _("Find sentence outline"),

                enabled_func = function()
                    return self.ui.document ~= nil
                end,

                callback = function()
                    self:findSentenceBoxes()
                end,
            },


            {
                text =
                    _("List first sentence"),

                enabled_func = function()
                    return self.ui.document ~= nil
                end,

                callback = function()
                    self:listSentence()
                end,
            },
        },
    }
end


------------------------------------------------------------
-- Toggle
------------------------------------------------------------

function SentenceExperiment:toggle()

    self.enabled =
        not self.enabled


    if self.enabled then

        self:findSentenceBoxes()

    else

        self.test_boxes = nil

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


    return document:getNextVisibleWordStart(
        page_xp
    )
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

    ["inc"] = true,
    ["ltd"] = true,
    ["co"] = true,
    ["corp"] = true,

    ["dept"] = true,
    ["min"] = true,
    ["max"] = true,

    ["am"] = true,
    ["pm"] = true,
}


------------------------------------------------------------
-- Sentence boundary
------------------------------------------------------------

local function isSentenceBoundary(
    word_text,
    gap_text
)

    if not gap_text then
        return false
    end


    if not gap_text:match(
        "^%s*[%.!?]"
    ) then

        return false
    end


    --------------------------------------------------------
    -- Question/exclamation marks are unambiguous.
    --------------------------------------------------------

    if not gap_text:match(
        "^%s*%."
    ) then

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
-- Find sentence
------------------------------------------------------------

function SentenceExperiment:getSentence(
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
            break
        end


        local gap =
            document:getTextFromXPointers(
                word_end,
                next_word_start
            ) or ""


        if isSentenceBoundary(
            word_text,
            gap
        ) then

            sentence_end =
                next_word_start

            break
        end


        local next_word_end =
            document:getNextVisibleWordEnd(
                next_word_start
            )


        if not next_word_end then
            break
        end


        word_start =
            next_word_start

        word_end =
            next_word_end

        sentence_end =
            word_end
    end


    return start_xp, sentence_end
end


------------------------------------------------------------
-- Draw one horizontal or vertical line
--
-- The sentence outline is intentionally composed only of
-- horizontal and vertical framebuffer rectangles.
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
            math.min(x1, x2)

        local w =
            math.abs(x2 - x1) + 1


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
            math.min(y1, y2)

        local h =
            math.abs(y2 - y1) + 1


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
    -- Normally the sentence outline never needs this.
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
            -- Find a line with a sufficiently close
            -- vertical center.
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
            -- Add box to existing line.
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
-- Add a point to polygon
------------------------------------------------------------

local function addPoint(
    points,
    x,
    y
)

    --------------------------------------------------------
    -- Avoid consecutive duplicate points.
    --------------------------------------------------------

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
-- Build the outside contour of the line rectangles
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
    -- Single line.
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
    -- RIGHT SIDE
    --
    -- Start at the top-right corner of the first line.
    --------------------------------------------------------

    local first =
        lines[1]


    addPoint(
        points,
        first.x,
        first.y
    )

    addPoint(
        points,
        first.x + first.w,
        first.y
    )


    --------------------------------------------------------
    -- Walk down the right side.
    --
    -- When the next line is shorter/longer, make a
    -- horizontal step at the boundary between the lines.
    --------------------------------------------------------

    for i = 1, #lines do

        local current =
            lines[i]


        local current_right =
            current.x + current.w

        local current_bottom =
            current.y + current.h


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
            -- Move horizontally to the next line's right
            -- edge.
            ------------------------------------------------

            addPoint(
                points,
                next_right,
                current_bottom
            )
        end
    end


    --------------------------------------------------------
    -- Bottom-right -> bottom-left.
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


        ------------------------------------------------
        -- Move vertically to top of current line.
        ------------------------------------------------

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
-- Draw small filled squares at corners
--
-- This makes the 90-degree steps look cleaner on e-ink
-- displays and prevents tiny gaps at corners.
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
-- Draw continuous sentence outline
------------------------------------------------------------

function SentenceExperiment:drawSentenceOutline(
    bb,
    boxes
)

    if not boxes
        or #boxes == 0 then

        return
    end


    --------------------------------------------------------
    -- Convert raw screen boxes into one rectangle per
    -- visual line.
    --------------------------------------------------------

    local lines =
        self:getLineBoxes(boxes)


    if #lines == 0 then
        return
    end


    --------------------------------------------------------
    -- Build the stepped outside contour.
    --------------------------------------------------------

    local points =
        self:buildSentenceOutline(lines)


    if #points < 2 then
        return
    end


    --------------------------------------------------------
    -- Outline thickness.
    --------------------------------------------------------

    local thickness = 2


    --------------------------------------------------------
    -- Draw every contour segment.
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
    -- Reinforce every corner.
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
-- Find ALL screen boxes belonging to first sentence
------------------------------------------------------------

function SentenceExperiment:findSentenceBoxes()

    local document =
        self.ui.document


    if not document then
        return
    end


    --------------------------------------------------------
    -- Find first word.
    --------------------------------------------------------

    local start_xp =
        self:getCurrentPageStart()


    if not start_xp then

        UIManager:show(
            InfoMessage:new{
                text = _(
                    "Couldn't find the first word."
                ),
            }
        )

        return
    end


    --------------------------------------------------------
    -- Find first sentence.
    --------------------------------------------------------

    local sentence_start,
        sentence_end =
        self:getSentence(
            start_xp
        )


    if not sentence_start
        or not sentence_end then

        UIManager:show(
            InfoMessage:new{
                text = _(
                    "Couldn't find a sentence."
                ),
            }
        )

        return
    end


    --------------------------------------------------------
    -- Get every screen box belonging to it.
    --------------------------------------------------------

    local ok, boxes =
        pcall(
            document.getScreenBoxesFromPositions,
            document,
            sentence_start,
            sentence_end
        )


    if not ok then

        UIManager:show(
            InfoMessage:new{
                text =
                    _("Geometry call failed:\n\n")
                    .. tostring(boxes),
            }
        )

        return
    end


    if not boxes
        or #boxes == 0 then

        UIManager:show(
            InfoMessage:new{
                text = _(
                    "No screen boxes returned."
                ),
            }
        )

        return
    end


    --------------------------------------------------------
    -- Copy the native boxes.
    --
    -- We deliberately retain the individual boxes here.
    -- drawSentenceOutline() performs the visual-line
    -- grouping later.
    --------------------------------------------------------

    self.test_boxes = {}


    for _, box in ipairs(boxes) do

        table.insert(
            self.test_boxes,
            {
                x = box.x,
                y = box.y,
                w = box.w,
                h = box.h,
            }
        )
    end


    --------------------------------------------------------
    -- Diagnostic information.
    --------------------------------------------------------

    local lines =
        self:getLineBoxes(
            self.test_boxes
        )


    logger.info(
        "SentenceExperiment:",
        "raw boxes =",
        #self.test_boxes,
        "visual lines =",
        #lines
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
-- Show sentence text
------------------------------------------------------------

function SentenceExperiment:listSentence()

    local document =
        self.ui.document

    if not document then
        return
    end


    local start_xp =
        self:getCurrentPageStart()


    if not start_xp then
        return
    end


    local start,
        finish =
        self:getSentence(
            start_xp
        )


    if not start
        or not finish then

        return
    end


    local text =
        document:getTextFromXPointers(
            start,
            finish
        )


    UIManager:show(
        InfoMessage:new{
            text =
                _("First sentence:\n\n")
                .. tostring(text),
        }
    )
end


------------------------------------------------------------
-- Page update
------------------------------------------------------------

function SentenceExperiment:onPageUpdate()

    if not self.enabled then
        return
    end


    self:findSentenceBoxes()
end


------------------------------------------------------------
-- Cleanup
------------------------------------------------------------

function SentenceExperiment:onCloseDocument()

    self.test_boxes = nil
end


return SentenceExperiment
