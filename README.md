gobo-awesome-bluetooth
======================

A Bluetooth widget for Awesome WM.

Requirements
------------

* Awesome 3.5+
* [Bluez](http://www.bluez.org)

Installing
----------

The easiest way to install it is via [LuaRocks](https://luarocks.org):


```
luarocks install gobo-awesome-bluetooth
```

Using
-----

Require the module:


```
local bluetooth = require("gobo.awesome.bluetooth")
```

Create the widget with `bluetooth.new()` and add to your layout.
In a typical `rc.lua` this will look like this:


```
right_layout:add(bluetooth.new())
```

