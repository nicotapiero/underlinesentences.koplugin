--[[
    Sentence Experiment - Multiple Box Drawing Test

    Version 2026-08-16.13

    This version draws a rectangle around EVERY screen box
    returned for the first sentence on the current page.

    It deliberately does NOT yet try to merge the boxes into
    one sophisticated sentence outline.

    The purpose of this version is to establish exactly how
    KOReader represents a multi-line sentence geometrically.
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


local Screen = Device.screen

local PLUGIN_VERSION =
    "2026-08-16.13"


------------------------------------------------------------
-- Plugin
------------------------------------------------------------

local SentenceExperiment = WidgetContainer:extend{
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
                -- Draw every box.
                ------------------------------------------------

                for _, box in ipairs(boxes) do

                    plugin:drawBox(
                        bb,
                        box
                    )
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
                        return _("Box test: ON")
                    else
                        return _("Box test: OFF")
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
                    _("Find sentence boxes"),

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
-- Safely draw one box
------------------------------------------------------------

function SentenceExperiment:drawBox(
    bb,
    box
)

    if not box then
        return
    end


    local bx =
        tonumber(box.x)

    local by =
        tonumber(box.y)

    local bw =
        tonumber(box.w)

    local bh =
        tonumber(box.h)


    if not bx
        or not by
        or not bw
        or not bh then

        return
    end


    if bw <= 0
        or bh <= 0 then

        return
    end


    --------------------------------------------------------
    -- Integer coordinates.
    --------------------------------------------------------

    bx =
        math.floor(bx)

    by =
        math.floor(by)

    bw =
        math.floor(bw)

    bh =
        math.floor(bh)


    --------------------------------------------------------
    -- Screen dimensions.
    --------------------------------------------------------

    local screen_w =
        Screen:getWidth()

    local screen_h =
        Screen:getHeight()


    --------------------------------------------------------
    -- Clip left.
    --------------------------------------------------------

    if bx < 0 then

        bw =
            bw + bx

        bx = 0
    end


    --------------------------------------------------------
    -- Clip top.
    --------------------------------------------------------

    if by < 0 then

        bh =
            bh + by

        by = 0
    end


    --------------------------------------------------------
    -- Clip right.
    --------------------------------------------------------

    if bx + bw > screen_w then

        bw =
            screen_w - bx
    end


    --------------------------------------------------------
    -- Clip bottom.
    --------------------------------------------------------

    if by + bh > screen_h then

        bh =
            screen_h - by
    end


    if bw <= 0
        or bh <= 0 then

        return
    end


    --------------------------------------------------------
    -- Draw a very thin outline.
    --------------------------------------------------------

    local thickness = 2


    --------------------------------------------------------
    -- Top.
    --------------------------------------------------------

    bb:paintRect(
        bx,
        by,
        bw,
        thickness,
        Blitbuffer.COLOR_BLACK
    )


    --------------------------------------------------------
    -- Bottom.
    --------------------------------------------------------

    bb:paintRect(
        bx,
        by + bh - thickness,
        bw,
        thickness,
        Blitbuffer.COLOR_BLACK
    )


    --------------------------------------------------------
    -- Left.
    --------------------------------------------------------

    bb:paintRect(
        bx,
        by,
        thickness,
        bh,
        Blitbuffer.COLOR_BLACK
    )


    --------------------------------------------------------
    -- Right.
    --------------------------------------------------------

    bb:paintRect(
        bx + bw - thickness,
        by,
        thickness,
        bh,
        Blitbuffer.COLOR_BLACK
    )
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
    -- Copy the boxes.
    --
    -- Don't retain the native table directly.
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


    logger.info(
        "SentenceExperiment: found",
        #self.test_boxes,
        "screen boxes"
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
