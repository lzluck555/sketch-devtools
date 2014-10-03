Sketch DevTools
===============

Sketch DevTools is a set of tools & utilities that help to develop [Sketch App](http://bohemiancoding.com/sketch/) plugins.

## Installation

1. [Download Sketch DevTools.zip archive file](https://github.com/turbobabr/sketch-devtools/blob/master/dist/Sketch%20DevTools.zip?raw=true).
2. Reveal plugins folder in finder ('Sketch App Menu' -> 'Plugins' -> 'Reveal Plugins Folder...').
3. Copy downloaded zip file to the revealed folder and un-zip it.
4. You are ready to go! :)

## Usage

### Shortcuts

`Command-Option-K` - Show/Hide Console
`Command-Option-Shift-K` - Clear Console

### Basic Logging

TODO: Text goes here!

### Jump to Code

Console allows you to quickly open a file on certain line with your IDE of choice. Before using this feature you have to select an editor you are using for Sketch plugins development:


All the default `print` statements and error boxes have an url with the name of actual file and line number that generated the record.

```JavaScript
print(selection);
print(selection.last());
```

## Roadmap

- [ ] A separate `console` CocoaScript module similar to the WebKit console that utilizes all the features of Sketch DevTools Console tab.
- [ ] Symbols Explorer. A separate tab panel that contains a Sketch classes reference.
- [ ] Custom script runner. The same thing as built-in Sketch custom script dialog but embedded right into DevTools panel.
- [ ] Console prompt to quickly evaluate JS expressions.

## Version history

> The project is under development...

## Feedback

If you discover any issue or have any suggestions for improvement of the plugin, please [open an issue](https://github.com/turbobabr/sketch-devtools/issues) or find me on twitter [@turbobabr](http://twitter.com/turbobabr).

## License

The MIT License (MIT)

Copyright (c) 2014 Andrey Shakhmin

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.