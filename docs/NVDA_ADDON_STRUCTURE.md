# NVDA Add-on Development Guide

This document contains patterns, classes, and best practices for developing NVDA add-ons, compiled from analysis of production add-ons.

## Environment

- **Python Version:** 3.11.9 (cannot be changed - NVDA bundles this version)
- **Platform:** Windows
- **Framework:** NVDA uses wxPython for GUI
- **NVDA Log Files:** `%tmp%\nvda.log` (current session), `%tmp%\nvda-old.log` (previous session)
- **Other APIs you can use that might not be covered here:** .engine folder

> **Development Tip:** After making changes, have the user restart NVDA, then check `%tmp%\nvda.log` for errors. If NVDA crashes on startup, the previous log at `%tmp%\nvda-old.log` contains the crash information.

---

## Add-on Directory Structure

```
AddonName/
├── manifest.ini                    # Required - add-on metadata
├── installTasks.py                 # Optional - install/uninstall hooks
├── globalPlugins/                  # Optional - global functionality
│   └── pluginName/
│       ├── __init__.py             # Main plugin module
│       └── submodules.py           # Additional modules
├── appModules/                     # Optional - app-specific modules
│   └── appname.py                  # Named after target application
├── synthDrivers/                   # Optional - speech synthesizers
│   └── drivername.py
├── locale/                         # Optional - translations
│   └── [lang_code]/
│       ├── LC_MESSAGES/
│       │   ├── nvda.po             # Source translations
│       │   └── nvda.mo             # Compiled translations
│       └── manifest.ini            # Language-specific metadata
└── doc/                            # Optional - documentation
    └── [lang_code]/
        └── readme.html
```

---

## manifest.ini Format

```ini
name = addonName
summary = "Short description"
description = """Longer description
can span multiple lines"""
author = "Author Name <email@example.com>"
url = https://github.com/user/addon
version = 1.0.0
docFileName = readme.html
minimumNVDAVersion = 2023.1.0
lastTestedNVDAVersion = 2025.1.0
updateChannel = None
```

---

## Core Classes

### GlobalPlugin (globalPluginHandler.GlobalPlugin)

Extends NVDA globally. Use for features that work across all applications.

```python
import globalPluginHandler
import addonHandler
import scriptHandler
import config
import ui
import wx
from gui.settingsDialogs import SettingsPanel, NVDASettingsDialog

addonHandler.initTranslation()

# Config specification
confspec = {
    "enabled": "boolean(default=True)",
    "volume": "integer(default=50, min=0, max=100)",
    "mode": 'string(default="auto")',
}

class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    # Category for input gestures dialog
    scriptCategory = _("My Add-on")

    def __init__(self):
        super().__init__()
        # Register config
        config.conf.spec["myAddon"] = confspec
        # Register settings panel
        NVDASettingsDialog.categoryClasses.append(MySettingsPanel)
        # Initialize state
        self.enabled = config.conf["myAddon"]["enabled"]

    def terminate(self):
        """Called when NVDA exits or add-on is disabled"""
        # Unregister settings panel
        NVDASettingsDialog.categoryClasses.remove(MySettingsPanel)
        # Save any state
        config.conf["myAddon"]["enabled"] = self.enabled

    @scriptHandler.script(
        description=_("Toggle feature on/off"),
        gesture="kb:NVDA+shift+f"
    )
    def script_toggleFeature(self, gesture):
        self.enabled = not self.enabled
        state = _("enabled") if self.enabled else _("disabled")
        ui.message(_("Feature {state}").format(state=state))
```

### AppModule (appModuleHandler.AppModule)

Targets specific applications. The module filename must match the application's executable name.

```python
# File: appModules/notepad.py (targets notepad.exe)
import appModuleHandler
import scriptHandler
import api
import ui
import controlTypes

class AppModule(appModuleHandler.AppModule):
    scriptCategory = _("Notepad Enhancements")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.lastLine = ""

    def chooseNVDAObjectOverlayClasses(self, obj, clsList):
        """Add custom overlay classes to specific controls"""
        if obj.role == controlTypes.Role.EDITABLETEXT:
            clsList.insert(0, EnhancedTextArea)

    @scriptHandler.script(
        description=_("Announce line count"),
        gesture="kb:control+shift+l"
    )
    def script_announceLineCount(self, gesture):
        obj = api.getFocusObject()
        if hasattr(obj, 'value') and obj.value:
            lines = obj.value.count('\n') + 1
            ui.message(_("{count} lines").format(count=lines))
```

### SynthDriver (synthDriverHandler.SynthDriver)

Provides text-to-speech synthesis.

```python
from synthDriverHandler import SynthDriver, VoiceInfo
from autoSettingsUtils.driverSetting import BooleanDriverSetting, NumericDriverSetting

class SynthDriver(synthDriverHandler.SynthDriver):
    name = "mySynth"
    description = "My Custom Synthesizer"

    supportedSettings = (
        SynthDriver.VoiceSetting(),
        SynthDriver.RateSetting(),
        SynthDriver.PitchSetting(),
        SynthDriver.VolumeSetting(),
        BooleanDriverSetting("enhancedMode", _("Enhanced mode"), False),
        NumericDriverSetting("quality", _("Quality"), False, minStep=1),
    )

    @classmethod
    def check(cls):
        """Return True if synth is available"""
        return True  # Check for required DLLs/dependencies

    def __init__(self):
        # Initialize synthesizer
        pass

    def speak(self, speechSequence):
        """Process and speak the given speech sequence"""
        for item in speechSequence:
            if isinstance(item, str):
                # Speak text
                pass

    def cancel(self):
        """Stop speaking"""
        pass

    def _get_availableVoices(self):
        """Return dict of available voices"""
        return {
            "voice1": VoiceInfo("voice1", _("Voice 1")),
            "voice2": VoiceInfo("voice2", _("Voice 2")),
        }
```

---

## Common NVDA API Imports

```python
# Core modules
import addonHandler          # Add-on management, translations
import globalPluginHandler   # GlobalPlugin base class
import appModuleHandler      # AppModule base class
import scriptHandler         # Script decorator and utilities
import config                # Configuration management
import ui                    # User interface (message, browse)
import api                   # NVDA API (focus, navigator, clipboard)
import speech                # Speech output
import braille               # Braille output
import tones                 # Audio feedback (beeps)
import core                  # Core NVDA functions (restart)
import queueHandler          # Queue operations
import globalVars            # Global variables
import controlTypes          # Control types and states

# UI modules
import gui                   # GUI utilities
from gui import guiHelper    # Layout helpers
from gui import nvdaControls # NVDA-specific controls
from gui import mainFrame    # Main NVDA frame
from gui.settingsDialogs import SettingsPanel, NVDASettingsDialog

# Object handling
from NVDAObjects import NVDAObject
from NVDAObjects.behaviors import Notification

# Script handling
from scriptHandler import script
from globalCommands import SCRCAT_CONFIG, SCRCAT_SPEECH

# Logging
from logHandler import log
```

---

## Generating User Interfaces

### Settings Panel (Integrates into NVDA Settings)

```python
from gui.settingsDialogs import SettingsPanel
from gui import guiHelper, nvdaControls
import wx
import config

class MySettingsPanel(SettingsPanel):
    title = _("My Add-on")

    def makeSettings(self, settingsSizer):
        # Create helper for layout
        sHelper = guiHelper.BoxSizerHelper(self, sizer=settingsSizer)

        # Checkbox
        self.enabledCheckbox = sHelper.addItem(
            wx.CheckBox(self, label=_("&Enable feature"))
        )
        self.enabledCheckbox.SetValue(config.conf["myAddon"]["enabled"])

        # Text input with label
        self.nameEdit = sHelper.addLabeledControl(
            _("&Name:"),
            wx.TextCtrl
        )
        self.nameEdit.SetValue(config.conf["myAddon"]["name"])

        # Spin control for numbers
        self.volumeSpinner = sHelper.addLabeledControl(
            _("&Volume:"),
            nvdaControls.SelectOnFocusSpinCtrl,
            min=0,
            max=100
        )
        self.volumeSpinner.SetValue(config.conf["myAddon"]["volume"])

        # Choice/dropdown
        self.modeChoice = sHelper.addLabeledControl(
            _("&Mode:"),
            wx.Choice,
            choices=[_("Auto"), _("Manual"), _("Disabled")]
        )
        self.modeChoice.SetSelection(0)

        # Checklist box
        self.optionsList = sHelper.addLabeledControl(
            _("&Options:"),
            nvdaControls.CustomCheckListBox,
            choices=[_("Option 1"), _("Option 2"), _("Option 3")]
        )
        self.optionsList.CheckedItems = [0, 2]  # Check items 0 and 2

        # Grouped settings with StaticBoxSizer
        groupLabel = _("Advanced Settings")
        groupSizer = wx.StaticBoxSizer(wx.VERTICAL, self, label=groupLabel)
        groupBox = groupSizer.GetStaticBox()
        groupHelper = guiHelper.BoxSizerHelper(self, sizer=groupSizer)

        self.advancedCheck = groupHelper.addItem(
            wx.CheckBox(groupBox, label=_("Advanced &option"))
        )

        sHelper.addItem(groupSizer)

        # Button
        self.configButton = sHelper.addItem(
            wx.Button(self, label=_("&Configure..."))
        )
        self.configButton.Bind(wx.EVT_BUTTON, self.onConfigButton)

    def onConfigButton(self, evt):
        # Open custom dialog
        dlg = MyCustomDialog(self)
        dlg.ShowModal()
        dlg.Destroy()

    def onSave(self):
        """Called when user clicks OK"""
        config.conf["myAddon"]["enabled"] = self.enabledCheckbox.GetValue()
        config.conf["myAddon"]["name"] = self.nameEdit.GetValue()
        config.conf["myAddon"]["volume"] = self.volumeSpinner.GetValue()
```

### Custom Dialog

```python
class MyCustomDialog(wx.Dialog):
    def __init__(self, parent):
        super().__init__(parent, title=_("Custom Settings"))
        self.InitUI()
        self.CenterOnParent()

    def InitUI(self):
        panel = wx.Panel(self)
        vbox = wx.BoxSizer(wx.VERTICAL)

        # Form layout with FlexGridSizer
        fgs = wx.FlexGridSizer(3, 2, 10, 10)  # rows, cols, vgap, hgap

        lblName = wx.StaticText(panel, label=_("Name:"))
        self.txtName = wx.TextCtrl(panel)

        lblValue = wx.StaticText(panel, label=_("Value:"))
        self.txtValue = wx.TextCtrl(panel)

        fgs.AddMany([
            lblName, (self.txtName, 1, wx.EXPAND),
            lblValue, (self.txtValue, 1, wx.EXPAND),
        ])
        fgs.AddGrowableCol(1, 1)

        vbox.Add(fgs, proportion=1, flag=wx.ALL | wx.EXPAND, border=10)

        # Standard dialog buttons
        btnsizer = wx.StdDialogButtonSizer()
        btnOK = wx.Button(panel, wx.ID_OK)
        btnOK.SetDefault()
        btnsizer.AddButton(btnOK)
        btnsizer.AddButton(wx.Button(panel, wx.ID_CANCEL))
        btnsizer.Realize()

        vbox.Add(btnsizer, flag=wx.ALIGN_CENTER | wx.BOTTOM, border=10)

        panel.SetSizer(vbox)
        self.Fit()
```

### Context Menus

```python
def onContextMenu(self, event):
    menu = wx.Menu()

    # Add menu items
    copyId = wx.NewIdRef()
    menu.Append(copyId, _("&Copy"))
    self.Bind(wx.EVT_MENU, self.onCopy, id=copyId)

    pasteId = wx.NewIdRef()
    menu.Append(pasteId, _("&Paste"))
    self.Bind(wx.EVT_MENU, self.onPaste, id=pasteId)

    menu.AppendSeparator()

    # Standard IDs
    menu.Append(wx.ID_SELECTALL)

    self.PopupMenu(menu)
    menu.Destroy()
```

### Opening Dialogs from Scripts

```python
@scriptHandler.script(description=_("Open settings"), gesture="kb:NVDA+shift+s")
def script_openSettings(self, gesture):
    # Must use wx.CallAfter for thread safety
    wx.CallAfter(self._showSettings)

def _showSettings(self):
    gui.mainFrame.popupSettingsDialog(NVDASettingsDialog, MySettingsPanel)
```

---

## Managing Keystrokes and Gestures

### Using @script Decorator (Recommended)

```python
from scriptHandler import script

class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    scriptCategory = _("My Add-on")

    # Simple gesture
    @script(
        description=_("Announce current time"),
        gesture="kb:NVDA+t"
    )
    def script_announceTime(self, gesture):
        import datetime
        ui.message(datetime.datetime.now().strftime("%H:%M"))

    # Multiple gestures (desktop + laptop)
    @script(
        description=_("Next item"),
        gestures=[
            "kb:control+windows+numpad6",
            "kb(laptop):control+windows+pagedown"
        ]
    )
    def script_nextItem(self, gesture):
        # Implementation
        pass

    # Touch gesture
    @script(
        description=_("Toggle feature"),
        gesture="ts:4finger_double_tap",
        speakOnDemand=True
    )
    def script_toggleViaTouch(self, gesture):
        pass

    # No default gesture (user configurable)
    @script(
        description=_("Custom action"),
        category=SCRCAT_CONFIG  # Use standard NVDA category
    )
    def script_customAction(self, gesture):
        pass
```

### Using __gestures Dictionary

```python
class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    def script_action1(self, gesture):
        ui.message("Action 1")

    def script_action2(self, gesture):
        ui.message("Action 2")

    # Map gestures to script names (without "script_" prefix)
    __gestures = {
        "kb:NVDA+1": "action1",
        "kb:NVDA+2": "action2",
        "kb:control+shift+a": "action1",
    }
```

### Dynamic Gesture Binding

```python
class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    def __init__(self):
        super().__init__()
        self.layerActive = False

        # Gestures for layer mode
        self._layerGestures = {
            "kb:1": "layerAction1",
            "kb:2": "layerAction2",
            "kb:escape": "exitLayer",
        }

    @script(description=_("Enter command layer"), gesture="kb:NVDA+l")
    def script_enterLayer(self, gesture):
        if self.layerActive:
            return
        self.layerActive = True
        self.bindGestures(self._layerGestures)
        tones.beep(400, 50)
        ui.message(_("Layer activated"))

    def script_exitLayer(self, gesture):
        self.layerActive = False
        self.clearGestureBindings()
        self.bindGestures(self.__gestures)
        ui.message(_("Layer deactivated"))

    def script_layerAction1(self, gesture):
        ui.message("Action 1")
        self.script_exitLayer(gesture)
```

### Script Repeat Count (Double/Triple Press)

```python
@script(description=_("Single/double press action"), gesture="kb:NVDA+r")
def script_repeatAction(self, gesture):
    repeatCount = scriptHandler.getLastScriptRepeatCount()
    if repeatCount == 0:
        ui.message(_("Single press"))
    elif repeatCount == 1:
        ui.message(_("Double press"))
    elif repeatCount == 2:
        ui.message(_("Triple press"))
```

### Sending Keystrokes Programmatically

```python
from keyboardHandler import KeyboardInputGesture

def sendKey(self, keyName):
    """Send a keyboard gesture"""
    KeyboardInputGesture.fromName(keyName).send()

# Examples:
self.sendKey("windows+h")      # Win+H
self.sendKey("control+c")      # Ctrl+C
self.sendKey("alt+tab")        # Alt+Tab
```

### Gesture Identifier Syntax

```
Keyboard gestures:
  kb:key                       - Any keyboard layout
  kb(laptop):key               - Laptop keyboard only
  kb(desktop):key              - Desktop keyboard only

Modifiers:
  ctrl, shift, alt, windows, nvda
  lctrl, rctrl, lshift, rshift, lalt, ralt

Keys:
  a-z, 0-9, f1-f24
  space, enter, escape, tab, backspace, delete
  home, end, pageup, pagedown
  uparrow, downarrow, leftarrow, rightarrow
  numpad0-numpad9, numpadplus, numpadminus, numpaddivide, numpadmultiply
  insert, capslock, numlock, scrolllock

Touch gestures:
  ts:tap, ts:2finger_tap, ts:3finger_tap, ts:4finger_tap
  ts:double_tap, ts:2finger_double_tap
  ts:flickLeft, ts:flickRight, ts:flickUp, ts:flickDown
  ts(Web):flickDown            - Mode-specific gesture
```

---

## Localization

### Setting Up Translations

```python
# At the TOP of your module, before other imports that use _()
import addonHandler
addonHandler.initTranslation()

# Now _() function is available
from scriptHandler import script

class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    # Translators: Category name shown in input gestures
    scriptCategory = _("My Add-on")

    @script(
        # Translators: Description for toggle feature script
        description=_("Toggle the feature on or off")
    )
    def script_toggle(self, gesture):
        # Translators: Message when feature is enabled
        ui.message(_("Feature enabled"))
```

### Using the Translation Function

```python
# Simple string
message = _("Hello, world!")

# String with formatting (use .format() AFTER _())
# Correct:
message = _("Found {count} items").format(count=5)
# WRONG - f-strings cannot be extracted:
# message = _(f"Found {count} items")

# Multi-line strings
description = _("""This is a long description
that spans multiple lines.""")
```

### Handling Plurals with ngettext

```python
from gettext import ngettext

def announceCount(self, count):
    # Translators: Singular/plural for item count
    message = ngettext(
        "{count} item",      # Singular
        "{count} items",     # Plural
        count                # Number to check
    ).format(count=count)
    ui.message(message)

# For time durations
def announceTime(self, hours, minutes):
    parts = []
    if hours > 0:
        # Translators: Hours in time display
        parts.append(ngettext(
            "{hours} hour",
            "{hours} hours",
            hours
        ).format(hours=hours))

    # Translators: Minutes in time display
    parts.append(ngettext(
        "{minutes} minute",
        "{minutes} minutes",
        minutes
    ).format(minutes=minutes))

    ui.message(", ".join(parts))
```

### Translator Comments

```python
# Place comment IMMEDIATELY before the translated string

# Translators: Button label for starting the process
label = _("Start")

# Translators: This message appears when no items are found
# in the search results list
message = _("No items found")

@script(
    # Translators: Description shown in NVDA's input gestures dialog
    # for the command that reads the current selection
    description=_("Read selection")
)
def script_readSelection(self, gesture):
    pass
```

### Locale Folder Structure

```
locale/
├── en/
│   ├── LC_MESSAGES/
│   │   ├── nvda.po          # English translations (source)
│   │   └── nvda.mo          # Compiled binary
│   └── manifest.ini         # English add-on description
├── es/
│   ├── LC_MESSAGES/
│   │   ├── nvda.po
│   │   └── nvda.mo
│   └── manifest.ini
└── fr/
    └── ...
```

### Sample .po File

```
# Language: Spanish
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"
"Language: es\n"
"Plural-Forms: nplurals=2; plural=(n != 1);\n"

#. Translators: Add-on summary
msgid "My Add-on"
msgstr "Mi Complemento"

#. Translators: Message when feature is enabled
msgid "Feature enabled"
msgstr "Característica habilitada"

#. Translators: Singular/plural for item count
#, python-brace-format
msgid "{count} item"
msgid_plural "{count} items"
msgstr[0] "{count} elemento"
msgstr[1] "{count} elementos"
```

---

## Dependency Management

### Bundling Dependencies

Place dependencies in a `lib/` folder within your plugin:

```
globalPlugins/
└── myPlugin/
    ├── __init__.py
    └── lib/
        ├── requests/
        ├── urllib3/
        └── other_package/
```

### Adding Bundled Libraries to Path

```python
import os
import sys

# Get path to lib directory
addon_dir = os.path.dirname(os.path.abspath(__file__))
lib_dir = os.path.join(addon_dir, "lib")

# Add to path if not already there
if lib_dir not in sys.path:
    sys.path.insert(0, lib_dir)  # Insert at beginning for priority

# Now import bundled libraries
import requests
```

### Optional Dependencies with Fallback

```python
import os
import sys

addon_dir = os.path.dirname(__file__)
sys.path.insert(0, addon_dir)

# Try to import optional dependency
try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    psutil = None
    PSUTIL_AVAILABLE = False

class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    def __init__(self):
        super().__init__()
        if not PSUTIL_AVAILABLE:
            log.warning("psutil not available, some features disabled")

    @script(description=_("Show CPU usage"))
    def script_showCPU(self, gesture):
        if not PSUTIL_AVAILABLE:
            ui.message(_("Feature unavailable - psutil not installed"))
            return

        cpu = psutil.cpu_percent()
        ui.message(_("{percent}% CPU").format(percent=cpu))
```

### Temporary Path Manipulation

```python
# Add path, import, then remove
addon_dir = os.path.dirname(__file__)
sys.path.append(addon_dir)

from mysubmodule import something

# Clean up immediately
del sys.path[-1]
```

### installTasks.py for Setup

```python
# installTasks.py - runs during add-on installation

from logHandler import log
import os
import shutil

def onInstall():
    """Called when add-on is installed"""
    log.info("My Add-on installed")

    # Check for required files
    addon_dir = os.path.dirname(__file__)
    required_file = os.path.join(addon_dir, "data", "config.json")

    if not os.path.exists(required_file):
        import gui
        import wx
        gui.messageBox(
            _("Required configuration file not found. Please configure the add-on."),
            _("Setup Required"),
            wx.OK | wx.ICON_WARNING
        )

def onUninstall():
    """Called when add-on is uninstalled"""
    log.info("My Add-on uninstalled")

    # Clean up config
    import config
    if "myAddon" in config.conf.spec:
        del config.conf.spec["myAddon"]
```

### Handling Module Conflicts

```python
# When another add-on might have a different version of a library
conflicting_libs = ["typing_extensions", "pydantic"]
original_modules = {}

# Save and remove conflicting modules
for lib in conflicting_libs:
    if lib in sys.modules:
        original_modules[lib] = sys.modules[lib]
        del sys.modules[lib]

try:
    # Import our version
    from .lib import pydantic
finally:
    # Restore original modules for other add-ons
    for lib, module in original_modules.items():
        sys.modules[lib] = module
```

---

## Configuration Management

### Config Specification Syntax

```python
confspec = {
    # Boolean with default
    "enabled": "boolean(default=True)",

    # Integer with range
    "volume": "integer(default=50, min=0, max=100)",

    # String with default
    "name": 'string(default="User")',

    # Empty string default
    "apiKey": 'string(default="")',

    # Choice from options
    "mode": 'option("auto", "manual", "disabled", default="auto")',

    # List (as string)
    "items": 'string(default="")',

    # Nested configuration
    "advanced": {
        "debug": "boolean(default=False)",
        "timeout": "integer(default=30, min=1, max=300)",
    },
}

# Register in __init__
config.conf.spec["myAddon"] = confspec
```

### Reading and Writing Config

```python
# Read values
enabled = config.conf["myAddon"]["enabled"]
volume = config.conf["myAddon"]["volume"]
debug = config.conf["myAddon"]["advanced"]["debug"]

# Write values
config.conf["myAddon"]["enabled"] = False
config.conf["myAddon"]["volume"] = 75

# Force save
config.conf.save()
```

---

## Event Handling

### Common Events in GlobalPlugin

```python
class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    def event_gainFocus(self, obj, nextHandler):
        """Called when any object gains focus"""
        # Process the focus change
        log.debug(f"Focus: {obj.name}, Role: {obj.role}")

        # ALWAYS call nextHandler to allow other handlers to run
        nextHandler()

    def event_foreground(self, obj, nextHandler):
        """Called when a new window comes to foreground"""
        log.debug(f"Foreground: {obj.name}")
        nextHandler()

    def event_nameChange(self, obj, nextHandler):
        """Called when an object's name changes"""
        nextHandler()

    def event_valueChange(self, obj, nextHandler):
        """Called when an object's value changes"""
        nextHandler()
```

### Common Events in AppModule

```python
class AppModule(appModuleHandler.AppModule):
    def event_NVDAObject_init(self, obj):
        """Modify object properties during initialization"""
        # Fix button names
        if obj.role == controlTypes.Role.BUTTON:
            if obj.name == "\ue8bb":  # Unicode icon
                obj.name = _("Close")

    def event_gainFocus(self, obj, nextHandler):
        """App-specific focus handling"""
        nextHandler()

    def chooseNVDAObjectOverlayClasses(self, obj, clsList):
        """Add custom overlay classes"""
        if obj.role == controlTypes.Role.LISTITEM:
            clsList.insert(0, EnhancedListItem)
```

### Overlay Classes for Custom Behavior

```python
from NVDAObjects.UIA import UIA

class EnhancedListItem(UIA):
    """Custom behavior for list items"""

    def initOverlayClass(self):
        """Called when overlay is applied"""
        # Add dynamic gestures
        self.bindGesture("kb:enter", "activate")
        self.bindGesture("kb:delete", "remove")

    def script_activate(self, gesture):
        self.doAction()
        ui.message(_("Activated"))

    def script_remove(self, gesture):
        ui.message(_("Item removed"))

    __gestures = {
        "kb:space": "activate",
        "kb:f2": "rename",
    }
```

---

## Threading and Async Operations

### Background Operations

```python
import threading
import wx

class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    @script(description=_("Fetch data"))
    def script_fetchData(self, gesture):
        ui.message(_("Fetching..."))

        def doFetch():
            try:
                # Long-running operation
                result = self._performFetch()
                # Update UI on main thread
                wx.CallAfter(self._onFetchComplete, result)
            except Exception as e:
                wx.CallAfter(self._onFetchError, str(e))

        thread = threading.Thread(target=doFetch, daemon=True)
        thread.start()

    def _onFetchComplete(self, result):
        ui.message(_("Fetch complete: {result}").format(result=result))

    def _onFetchError(self, error):
        ui.message(_("Fetch failed: {error}").format(error=error))
```

### Using wx.Timer

```python
class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    def __init__(self):
        super().__init__()
        self.timer = wx.Timer()
        self.timer.Bind(wx.EVT_TIMER, self.onTimer)

    def startMonitoring(self):
        self.timer.Start(1000)  # Every 1000ms

    def stopMonitoring(self):
        self.timer.Stop()

    def onTimer(self, event):
        # Periodic check
        self.checkStatus()

    def terminate(self):
        self.timer.Stop()
```

---

## Best Practices and Tips

### General Tips

1. **Always call `addonHandler.initTranslation()` early** - Before any imports that might use `_()`

2. **Always call `nextHandler()` in event handlers** - Allows other plugins to process events

3. **Use `wx.CallAfter()` for UI operations from threads** - wxPython is not thread-safe

4. **Register and unregister settings panels** - In `__init__` and `terminate`

5. **Use type hints** - Python 3.11 supports modern type hints

6. **Log appropriately** - Use `log.debug()`, `log.info()`, `log.warning()`, `log.error()`

### Accessibility Tips

1. **Provide good script descriptions** - They appear in NVDA's input gestures dialog

2. **Use `ui.message()` for important feedback** - Works with both speech and braille

3. **Support both keyboard layouts** - Desktop (numpad) and laptop layouts

4. **Test with screen reader** - Actually use NVDA to test your add-on

### Code Organization

```python
# Recommended file structure for complex add-ons
globalPlugins/
└── myAddon/
    ├── __init__.py      # GlobalPlugin class, minimal imports
    ├── gui.py           # Settings panels and dialogs
    ├── config.py        # Configuration handling
    ├── utils.py         # Utility functions
    ├── api.py           # External API interactions
    └── lib/             # Bundled dependencies
```

### Error Handling

```python
from logHandler import log

def safeOperation(self):
    try:
        result = self.riskyOperation()
        return result
    except SpecificError as e:
        log.warning(f"Expected error: {e}")
        ui.message(_("Operation failed"))
    except Exception as e:
        log.error(f"Unexpected error: {e}", exc_info=True)
        ui.message(_("An error occurred"))
```

### Testing Your Add-on

1. Place add-on folder in NVDA's `addons` directory
2. Restart NVDA or use developer tools to reload
3. Check NVDA log (NVDA+F1, then Tools > View Log) for errors
4. Test all gestures and features
5. Test with different NVDA settings (speech, braille, etc.)

### Debugging

```python
from logHandler import log

# Different log levels
log.debug("Detailed debug info")      # Only in debug mode
log.info("General information")        # Normal operation
log.warning("Warning message")         # Potential issues
log.error("Error message")             # Errors
log.error("Error with trace", exc_info=True)  # Include stack trace

# Quick audio feedback for debugging
import tones
tones.beep(440, 100)  # Frequency Hz, duration ms
```

---

## Quick Reference

### Announcing Messages

```python
import ui

ui.message("Text to speak")           # Speech + braille
ui.message("Text", speechPriority=1)  # High priority
speech.speakText("Direct speech")     # Speech only
braille.handler.message("Braille")    # Braille only
```

### Accessing Objects

```python
import api

focus = api.getFocusObject()          # Currently focused object
nav = api.getNavigatorObject()        # Navigator object
fg = api.getForegroundObject()        # Foreground window
desktop = api.getDesktopObject()      # Desktop
```

### Clipboard

```python
import api

api.copyToClip("Text to copy")        # Copy to clipboard
text = api.getClipData()              # Get clipboard text
```

### Playing Sounds

```python
import tones
import nvwave

tones.beep(440, 100)                  # Simple beep
nvwave.playWaveFile("path/to/file.wav")  # Play WAV file
```

### Restarting NVDA

```python
import core

core.restart()                        # Restart NVDA
core.restart(disableAddons=True)      # Restart without add-ons
```
