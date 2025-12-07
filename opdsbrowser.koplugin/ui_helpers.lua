local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local UIHelpers = {}

-- Create a standard menu
function UIHelpers.createMenu(title, items, options)
    options = options or {}
    
    return Menu:new{
        title = title or _("Menu"),
        item_table = items,
        is_borderless = options.is_borderless ~= false,
        is_popout = options.is_popout or false,
        title_bar_fm_style = options.title_bar_fm_style ~= false,
        onMenuHold = options.onMenuHold or function() return true end,
        width = options.width or Screen:getWidth(),
        height = options.height or Screen:getHeight(),
    }
end

-- Show an info message
function UIHelpers.showInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

-- Show a loading message
function UIHelpers.showLoading(text)
    return InfoMessage:new{
        text = text or _("Loading..."),
    }
end

-- Create an input dialog
function UIHelpers.createInputDialog(title, hint, callback, cancel_callback)
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = "",
        input_hint = hint,
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if cancel_callback then
                            cancel_callback()
                        end
                    end
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local input_text = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if callback then
                            callback(input_text)
                        end
                    end
                },
            },
        },
    }
    
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
    
    return input_dialog
end

-- Create a multi-input dialog
function UIHelpers.createMultiInputDialog(title, fields, callback, extra_text)
    local dialog
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                },
                {
                    text = _("Save"),
                    callback = function()
                        local field_values = dialog:getFields()
                        UIManager:close(dialog)
                        if callback then
                            callback(field_values)
                        end
                    end
                },
            },
        },
        extra_text = extra_text,
    }
    
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    
    return dialog
end

-- Create a text viewer with buttons
function UIHelpers.createTextViewer(title, text, buttons_table)
    return TextViewer:new{
        title = title,
        text = text,
        buttons_table = buttons_table,
    }
end

-- Create a confirmation dialog
function UIHelpers.createConfirmDialog(title, text, ok_callback, cancel_callback)
    local ButtonDialog = require("ui/widget/buttondialog")
    
    local dialog
    dialog = ButtonDialog:new{
        title = title,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        if cancel_callback then
                            cancel_callback()
                        end
                    end
                },
                {
                    text = _("OK"),
                    callback = function()
                        UIManager:close(dialog)
                        if ok_callback then
                            ok_callback()
                        end
                    end
                },
            },
        },
    }
    
    UIManager:show(dialog)
    return dialog
end

-- Show error message
function UIHelpers.showError(message, timeout)
    UIManager:show(InfoMessage:new{
        text = _("Error: ") .. message,
        timeout = timeout or 5,
    })
end

-- Show success message
function UIHelpers.showSuccess(message, timeout)
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = timeout or 3,
    })
end

-- Create a progress message (can be updated)
function UIHelpers.createProgressMessage(text)
    return InfoMessage:new{
        text = text or _("Processing..."),
    }
end

-- Update progress message text
function UIHelpers.updateProgressMessage(message_widget, new_text)
    if message_widget and message_widget.label_widget then
        message_widget.label_widget:setText(new_text)
        UIManager:setDirty(message_widget, "ui")
    end
end

return UIHelpers
