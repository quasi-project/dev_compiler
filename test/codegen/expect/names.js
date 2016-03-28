dart_library.library('names', null, /* Imports */[
  'dart/_runtime',
  'dart/core'
], /* Lazy imports */[
], function(exports, dart, core) {
  'use strict';
  let dartx = dart.dartx;
  exports[dart.uri] = 'file:///usr/local/google/vsm/dev_compiler/test/codegen/names.dart';
  exports.exports = 42;
  const _foo$ = Symbol('_foo');
  class Foo extends core.Object {
    [_foo$]() {
      return 123;
    }
  }
  dart.setSignature(Foo, {
    methods: () => ({[_foo$]: [dart.dynamic, []]})
  });
  Foo[dart.owner] = exports;
  function _foo() {
    return 456;
  }
  dart.fn(_foo);
  class Frame extends core.Object {
    caller(arguments$) {
      this.arguments = arguments$;
    }
    static callee() {
      return null;
    }
  }
  dart.defineNamedConstructor(Frame, 'caller');
  dart.setSignature(Frame, {
    constructors: () => ({caller: [Frame, [core.List]]}),
    statics: () => ({callee: [dart.dynamic, []]}),
    names: ['callee']
  });
  Frame[dart.owner] = exports;
  class Frame2 extends core.Object {}
  Frame2[dart.owner] = exports;
  dart.defineLazyProperties(Frame2, {
    get caller() {
      return 100;
    },
    set caller(_) {},
    get arguments() {
      return 200;
    },
    set arguments(_) {}
  });
  function main() {
    core.print(exports.exports);
    core.print(new Foo()[_foo$]());
    core.print(_foo());
    core.print(new Frame.caller(dart.list([1, 2, 3], core.int)));
    let eval$ = Frame.callee;
    core.print(eval$);
    core.print(dart.notNull(Frame2.caller) + dart.notNull(Frame2.arguments));
  }
  dart.fn(main);
  // Exports:
  exports.Foo = Foo;
  exports.Frame = Frame;
  exports.Frame2 = Frame2;
  exports.main = main;
});
