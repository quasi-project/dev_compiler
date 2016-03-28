dart_library.library('dom/dom', window, /* Imports */[
  'dart/_runtime',
  'dart/core'
], /* Lazy imports */[
], function(exports, dart, core) {
  'use strict';
  let dartx = dart.dartx;
  exports[dart.uri] = 'package:dom/dom.dart';
  class Overload extends core.Object {
    Overload() {
    }
  }
  dart.setSignature(Overload, {
    constructors: () => ({Overload: [Overload, []]})
  });
  Overload[dart.owner] = exports;
  const overload = dart.const(new Overload());
  class CustomEvent extends core.Object {}
  dart.setSignature(CustomEvent, {
    constructors: () => ({CustomEvent: [CustomEvent, [core.String], {detail: dart.dynamic, bubbles: dart.dynamic, cancelable: dart.dynamic}]})
  });
  CustomEvent[dart.owner] = exports;
  class HTMLCollection extends core.Object {
    get(index) {
      return this["[]"](index);
    }
  }
  dart.setSignature(HTMLCollection, {
    methods: () => ({get: [Element, [core.num]]})
  });
  HTMLCollection[dart.owner] = exports;
  const EventListener = dart.typedef('EventListener', () => dart.functionType(dart.void, [Event]));
  const InputElement = HTMLInputElement;
  const CanvasElement = HTMLCanvasElement;
  const DivElement = HTMLDivElement;
  const ScriptElement = HTMLScriptElement;
  class RenderingContext extends core.Object {}
  RenderingContext[dart.owner] = exports;
  class CanvasDrawingStyles extends core.Object {
    CanvasDrawingStyles() {
      this.lineWidth = null;
      this.lineCap = null;
      this.lineJoin = null;
      this.miterLimit = null;
      this.lineDashOffset = null;
      this.font = null;
      this.textAlign = null;
      this.textBaseline = null;
    }
  }
  CanvasDrawingStyles[dart.owner] = exports;
  class CanvasPathMethods extends core.Object {}
  CanvasPathMethods[dart.owner] = exports;
  // Exports:
  exports.Overload = Overload;
  exports.overload = overload;
  exports.CustomEvent = CustomEvent;
  exports.HTMLCollection = HTMLCollection;
  exports.EventListener = EventListener;
  exports.InputElement = InputElement;
  exports.CanvasElement = CanvasElement;
  exports.DivElement = DivElement;
  exports.ScriptElement = ScriptElement;
  exports.RenderingContext = RenderingContext;
  exports.CanvasDrawingStyles = CanvasDrawingStyles;
  exports.CanvasPathMethods = CanvasPathMethods;
});
