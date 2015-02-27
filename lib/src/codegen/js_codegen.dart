// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library ddc.src.codegen.js_codegen;

import 'dart:io' show Directory, File;

import 'package:analyzer/analyzer.dart' hide ConstantEvaluator;
import 'package:analyzer/src/generated/ast.dart' hide ConstantEvaluator;
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/scanner.dart'
    show StringToken, Token, TokenType;
import 'package:path/path.dart' as path;

// TODO(jmesserly): import from its own package
import 'package:dev_compiler/src/js/js_ast.dart' as JS;
import 'package:dev_compiler/src/js/js_ast.dart' show js;

import 'package:dev_compiler/src/checker/rules.dart';
import 'package:dev_compiler/src/info.dart';
import 'package:dev_compiler/src/report.dart';
import 'package:dev_compiler/src/utils.dart';
import 'code_generator.dart';

// This must match the optional parameter name used in runtime.js
const String _jsNamedParameterName = r'opt$';

class JSCodegenVisitor extends GeneralizingAstVisitor with ConversionVisitor {
  final LibraryInfo libraryInfo;
  final TypeRules rules;
  final String _libraryName;

  /// The variable for the target of the current `..` cascade expression.
  SimpleIdentifier _cascadeTarget;

  ClassDeclaration currentClass;
  ConstantEvaluator _constEvaluator;

  final _exports = <String>[];
  final _lazyFields = <VariableDeclaration>[];
  final _properties = <FunctionDeclaration>[];

  JSCodegenVisitor(LibraryInfo libraryInfo, TypeRules rules)
      : libraryInfo = libraryInfo,
        rules = rules,
        _libraryName = jsLibraryName(libraryInfo.library);

  Element get currentLibrary => libraryInfo.library;

  JS.Block generateLibrary(
      Iterable<CompilationUnit> units, CheckerReporter reporter) {
    var body = <JS.Statement>[];
    for (var unit in units) {
      // TODO(jmesserly): this is needed because RestrictedTypeRules can send
      // messages to CheckerReporter, for things like missing types.
      // We should probably refactor so this can't happen.
      var source = unit.element.source;
      _constEvaluator = new ConstantEvaluator(source, rules.provider);
      reporter.enterSource(source);
      body.add(unit.accept(this));
      reporter.leaveSource();
    }

    if (_exports.isNotEmpty) body.add(js.comment('Exports:'));

    // TODO(jmesserly): make these immutable in JS?
    for (var name in _exports) {
      body.add(js.statement('#.# = #;', [_libraryName, name, name]));
    }

    var name = _libraryName;
    return new JS.Block([
      js.statement('var #;', name),
      js.statement('''
        (function (#) {
          'use strict';
          #;
        })(# || (# = {}));
      ''', [name, body, name, name])
    ]);
  }

  @override
  JS.Statement visitCompilationUnit(CompilationUnit node) {
    // TODO(jmesserly): scriptTag, directives.
    var body = <JS.Statement>[];
    for (var child in node.declarations) {
      // Attempt to group adjacent fields/properties.
      if (child is! TopLevelVariableDeclaration) _flushLazyFields(body);
      if (child is! FunctionDeclaration) _flushLibraryProperties(body);

      var code = child.accept(this);
      if (code != null) body.add(code);
    }
    // Flush any unwritten fields/properties.
    _flushLazyFields(body);
    _flushLibraryProperties(body);
    return _statement(body);
  }

  bool isPublic(String name) => !name.startsWith('_');

  /// Conversions that we don't handle end up here.
  @override
  visitConversion(Conversion node) {
    var from = node.baseType;
    var to = node.convertedType;

    // All Dart number types map to a JS double.
    if (rules.isNumType(from) &&
        (rules.isIntType(to) || rules.isDoubleType(to))) {
      // TODO(jmesserly): a lot of these checks are meaningless, as people use
      // `num` to mean "any kind of number" rather than "could be null".
      // The core libraries especially suffer from this problem, with many of
      // the `num` methods returning `num`.
      if (!rules.isNonNullableType(from) && rules.isNonNullableType(to)) {
        // Converting from a nullable number to a non-nullable number
        // only requires a null check.
        return js.call('dart.notNull(#)', node.expression.accept(this));
      } else {
        // A no-op in JavaScript.
        return node.expression.accept(this);
      }
    }

    return _emitCast(node.expression, to);
  }

  @override
  visitAsExpression(AsExpression node) =>
      _emitCast(node.expression, node.type.type);

  _emitCast(Expression node, DartType type) =>
      js.call('dart.as(#)', [[node.accept(this), _emitTypeName(type)]]);

  @override
  visitIsExpression(IsExpression node) {
    // Generate `is` as `dart.is` or `typeof` depending on the RHS type.
    JS.Expression result;
    var type = node.type.type;
    var lhs = node.expression.accept(this);
    var typeofName = _jsTypeofName(type);
    if (typeofName != null) {
      result = js.call('typeof # == #', [lhs, typeofName]);
    } else {
      // Always go through a runtime helper, because implicit interfaces.
      result = js.call('dart.is(#, #)', [lhs, _emitTypeName(type)]);
    }

    if (node.notOperator != null) {
      return js.call('!#', result);
    }
    return result;
  }

  String _jsTypeofName(DartType t) {
    if (rules.isIntType(t) || rules.isDoubleType(t)) return 'number';
    if (rules.isStringType(t)) return 'string';
    if (rules.isBoolType(t)) return 'boolean';
    return null;
  }

  @override
  visitFunctionTypeAlias(FunctionTypeAlias node) {
    // TODO(vsm): Do we need to record type info the generated code for a
    // typedef?
  }

  @override
  JS.Expression visitTypeName(TypeName node) => _emitTypeName(node.type);

  @override
  JS.Statement visitClassTypeAlias(ClassTypeAlias node) {
    var name = node.name.name;
    var heritage =
        js.call('dart.mixin(#)', [_visitList(node.withClause.mixinTypes)]);
    var classDecl = new JS.ClassDeclaration(
        new JS.ClassExpression(new JS.VariableDeclaration(name), heritage, []));
    if (isPublic(name)) _exports.add(name);
    return _addTypeParameters(node.typeParameters, name, classDecl);
  }

  @override
  visitTypeParameter(TypeParameter node) => new JS.Parameter(node.name.name);

  JS.Statement _addTypeParameters(
      TypeParameterList node, String name, JS.Statement clazz) {
    if (node == null) return clazz;

    var genericName = '$name\$';
    var genericDef = js.statement(
        'let # = dart.generic(function(#) { #; return #; });', [
      genericName,
      _visitList(node.typeParameters),
      clazz,
      name
    ]);

    // TODO(jmesserly): we may not want this to be `dynamic` if the generic
    // has a lower bound, e.g. `<T extends SomeType>`.
    // https://github.com/dart-lang/dart-dev-compiler/issues/38
    var typeArgs = new List.filled(node.typeParameters.length, 'dynamic');

    var dynInst = js.statement('let # = #(#);', [name, genericName, typeArgs]);

    // TODO(jmesserly): is it worth exporting both names? Alternatively we could
    // put the generic type constructor on the <dynamic> instance.
    if (isPublic(name)) _exports.add('${name}\$');
    return new JS.Block([genericDef, dynInst]);
  }

  @override
  JS.Statement visitClassDeclaration(ClassDeclaration node) {
    currentClass = node;

    var body = <JS.Statement>[];

    var name = node.name.name;
    var ctors = <ConstructorDeclaration>[];
    var fields = <FieldDeclaration>[];
    var staticFields = <FieldDeclaration>[];
    for (var member in node.members) {
      if (member is ConstructorDeclaration) {
        ctors.add(member);
      } else if (member is FieldDeclaration) {
        (member.isStatic ? staticFields : fields).add(member);
      }
    }

    var jsMethods = <JS.Method>[];
    // Iff no constructor is specified for a class C, it implicitly has a
    // default constructor `C() : super() {}`, unless C is class Object.
    if (ctors.isEmpty && !node.element.type.isObject) {
      jsMethods.add(_emitImplicitConstructor(node, name, fields));
    }

    for (var member in node.members) {
      if (member is ConstructorDeclaration) {
        jsMethods.add(_emitConstructor(member, name, fields));
      } else if (member is MethodDeclaration) {
        jsMethods.add(member.accept(this));
      }
    }

    // Support for adapting dart:core Iterator/Iterable to ES6 versions.
    // This lets them use for-of loops transparently.
    // https://github.com/lukehoban/es6features#iterators--forof
    if (node.element.library.isDartCore && node.element.name == 'Iterable') {
      JS.Fun body = js.call('''function() {
        var iterator = this.iterator;
        return {
          next() {
            var done = iterator.moveNext();
            return { done: done, current: done ? void 0 : iterator.current };
          }
        };
      }''');
      jsMethods.add(new JS.Method(js.call('Symbol.iterator'), body));
    }

    JS.Expression heritage;
    if (node.extendsClause != null) {
      heritage = _visit(node.extendsClause.superclass);
    } else {
      heritage = js.call('dart.Object');
    }
    if (node.withClause != null) {
      var mixins = _visitList(node.withClause.mixinTypes);
      mixins.insert(0, heritage);
      heritage = js.call('dart.mixin(#)', [mixins]);
    }
    body.add(new JS.ClassDeclaration(new JS.ClassExpression(
        new JS.VariableDeclaration(name), heritage,
        jsMethods.where((m) => m != null).toList(growable: false))));

    if (isPublic(name)) _exports.add(name);

    // Named constructors
    for (ConstructorDeclaration member in ctors) {
      if (member.name != null) {
        body.add(js.statement('dart.defineNamedConstructor(#, #);', [
          name,
          js.string(member.name.name, "'")
        ]));
      }
    }

    // Static fields
    var lazyStatics = <VariableDeclaration>[];
    for (FieldDeclaration member in staticFields) {
      for (VariableDeclaration field in member.fields.variables) {
        var fieldName = field.name.name;
        if (field.isConst || _isFieldInitConstant(field)) {
          var init = _visit(field.initializer);
          if (init == null) init = new JS.LiteralNull();
          body.add(js.statement('#.# = #;', [name, fieldName, init]));
        } else {
          lazyStatics.add(field);
        }
      }
    }
    var lazy = _emitLazyFields(name, lazyStatics);
    if (lazy != null) body.add(lazy);

    currentClass = null;
    return _addTypeParameters(node.typeParameters, name, _statement(body));
  }

  /// Generates the implicit default constructor for class C of the form
  /// `C() : super() {}`.
  JS.Method _emitImplicitConstructor(
      ClassDeclaration node, String name, List<FieldDeclaration> fields) {
    // If we don't have a method body, skip this.
    if (fields.isEmpty) return null;

    dynamic body = _initializeFields(fields);
    var superCall = _superConstructorCall(node);
    if (superCall != null) body = [[body, superCall]];
    return new JS.Method(
        new JS.PropertyName(name), js.call('function() { #; }', body));
  }

  JS.Method _emitConstructor(ConstructorDeclaration node, String className,
      List<FieldDeclaration> fields) {
    if (_externalOrNative(node)) return null;

    var name = _constructorName(className, node.name);

    // We generate constructors as initializer methods in the class;
    // this allows use of `super` for instance methods/properties.
    // It also avoids V8 restrictions on `super` in default constructors.
    return new JS.Method(new JS.PropertyName(name), new JS.Fun(
        node.parameters.accept(this), _emitConstructorBody(node, fields)));
  }

  String _constructorName(String className, SimpleIdentifier name) {
    if (name == null) return className;
    return '$className\$${name.name}';
  }

  JS.Block _emitConstructorBody(
      ConstructorDeclaration node, List<FieldDeclaration> fields) {
    // Wacky factory redirecting constructors: factory Foo.q(x, y) = Bar.baz;
    if (node.redirectedConstructor != null) {
      return js.statement('{ return new #(#); }', [
        node.redirectedConstructor.accept(this),
        node.parameters.accept(this)
      ]);
    }

    var body = <JS.Statement>[];

    // Generate optional/named argument value assignment. These can not have
    // side effects, and may be used by the constructor's initializers, so it's
    // nice to do them first.
    var init = _emitArgumentInitializers(node.parameters);
    if (init != null) body.add(init);

    // Redirecting constructors: these are not allowed to have initializers,
    // and the redirecting ctor invocation runs before field initializers.
    var redirectCall = node.initializers.firstWhere(
        (i) => i is RedirectingConstructorInvocation, orElse: () => null);

    if (redirectCall != null) {
      body.add(redirectCall.accept(this));
      return new JS.Block(body);
    }

    // Initializers only run for non-factory constructors.
    if (node.factoryKeyword == null) {
      // Generate field initializers.
      // These are expanded into each non-redirecting constructor.
      // In the future we may want to create an initializer function if we have
      // multiple constructors, but it needs to be balanced against readability.
      body.add(_initializeFields(fields, node.parameters, node.initializers));

      var superCall = node.initializers.firstWhere(
          (i) => i is SuperConstructorInvocation, orElse: () => null);

      // If no superinitializer is provided, an implicit superinitializer of the
      // form `super()` is added at the end of the initializer list, unless the
      // enclosing class is class Object.
      var jsSuper = _superConstructorCall(node.parent, superCall);
      if (jsSuper != null) body.add(jsSuper);
    }

    body.add(node.body.accept(this));
    return new JS.Block(body);
  }

  @override
  JS.Statement visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    ClassDeclaration classDecl = node.parent.parent;
    var className = classDecl.name.name;

    var name = _constructorName(className, node.constructorName);
    return js.statement('this.#(#);', [name, node.argumentList.accept(this)]);
  }

  JS.Statement _superConstructorCall(ClassDeclaration clazz,
      [SuperConstructorInvocation node]) {
    var superCtorName = node != null ? node.constructorName : null;

    var element = clazz.element;
    if (superCtorName == null &&
        (element.type.isObject || element.supertype.isObject)) {
      return null;
    }

    var supertypeName = element.supertype.name;
    var name = _constructorName(supertypeName, superCtorName);

    var args = node != null ? node.argumentList.accept(this) : [];
    return js.statement('super.#(#);', [name, args]);
  }

  /// Initialize fields. They follow the sequence:
  ///
  ///   1. field declaration initializer if non-const,
  ///   2. field initializing parameters,
  ///   3. constructor field initializers,
  ///   4. initialize fields not covered in 1-3
  JS.Statement _initializeFields(List<FieldDeclaration> fields,
      [FormalParameterList parameters,
      NodeList<ConstructorInitializer> initializers]) {
    var body = <JS.Statement>[];

    // Run field initializers if they can have side-effects.
    var unsetFields = new Map<String, VariableDeclaration>();
    for (var declaration in fields) {
      for (var field in declaration.fields.variables) {
        if (_isFieldInitConstant(field)) {
          unsetFields[field.name.name] = field;
        } else {
          body.add(js.statement(
              '# = #;', [field.name.accept(this), _visitInitializer(field)]));
        }
      }
    }

    // Initialize fields from `this.fieldName` parameters.
    if (parameters != null) {
      for (var p in parameters.parameters) {
        if (p is DefaultFormalParameter) p = p.parameter;
        if (p is FieldFormalParameter) {
          var name = p.identifier.name;
          body.add(js.statement('this.# = #;', [name, name]));
          unsetFields.remove(name);
        }
      }
    }

    // Run constructor field initializers such as `: foo = bar.baz`
    if (initializers != null) {
      for (var init in initializers) {
        if (init is ConstructorFieldInitializer) {
          body.add(js.statement('# = #;', [
            init.fieldName.accept(this),
            init.expression.accept(this)
          ]));
          unsetFields.remove(init.fieldName.name);
        }
      }
    }

    // Initialize all remaining fields
    unsetFields.forEach((name, field) {
      JS.Expression value;
      if (field.initializer != null) {
        value = field.initializer.accept(this);
      } else {
        var type = rules.elementType(field.element);
        if (rules.maybeNonNullableType(type)) {
          value = js.call('dart.as(null, #)', _emitTypeName(type));
        } else {
          value = new JS.LiteralNull();
        }
      }
      body.add(js.statement('this.# = #;', [name, value]));
    });

    return _statement(body);
  }

  FormalParameterList _parametersOf(node) {
    // Note: ConstructorDeclaration is intentionally skipped here so we can
    // emit the argument initializers in a different place.
    // TODO(jmesserly): clean this up. If we can model ES6 spread/rest args, we
    // could handle argument initializers more consistently in a separate
    // lowering pass.
    if (node is MethodDeclaration) return node.parameters;
    if (node is FunctionDeclaration) node = node.functionExpression;
    if (node is FunctionExpression) return node.parameters;
    return null;
  }

  bool _hasArgumentInitializers(FormalParameterList parameters) {
    if (parameters == null) return false;
    return parameters.parameters.any((p) => p.kind != ParameterKind.REQUIRED);
  }

  JS.Statement _emitArgumentInitializers(FormalParameterList parameters) {
    if (parameters == null || !_hasArgumentInitializers(parameters)) {
      return null;
    }

    var body = [];
    for (var param in parameters.parameters) {
      // TODO(justinfagnani): rename identifier if necessary
      var name = param.identifier.name;

      if (param.kind == ParameterKind.NAMED) {
        body.add(js.statement('let # = opt\$.# === void 0 ? # : opt\$.#;', [
          name,
          name,
          _defaultParamValue(param),
          name
        ]));
      } else if (param.kind == ParameterKind.POSITIONAL) {
        body.add(js.statement('if (# === void 0) # = #;', [
          name,
          name,
          _defaultParamValue(param)
        ]));
      }
    }
    return _statement(body);
  }

  JS.Expression _defaultParamValue(FormalParameter param) {
    if (param is DefaultFormalParameter && param.defaultValue != null) {
      return param.defaultValue.accept(this);
    } else {
      return new JS.LiteralNull();
    }
  }

  @override
  JS.Method visitMethodDeclaration(MethodDeclaration node) {
    if (node.isAbstract || _externalOrNative(node)) {
      return null;
    }

    var params = _visit(node.parameters);
    if (params == null) params = [];

    return new JS.Method(new JS.PropertyName(_jsMethodName(node.name.name)),
        new JS.Fun(params, node.body.accept(this)),
        isGetter: node.isGetter,
        isSetter: node.isSetter,
        isStatic: node.isStatic);
  }

  @override
  JS.Statement visitFunctionDeclaration(FunctionDeclaration node) {
    assert(node.parent is CompilationUnit);

    if (_externalOrNative(node)) return null;

    if (node.isGetter || node.isSetter) {
      // Add these later so we can use getter/setter syntax.
      _properties.add(node);
      return null;
    }

    var body = <JS.Statement>[];
    _flushLibraryProperties(body);

    var name = node.name.name;
    body.add(js.comment('Function $name: ${node.element.type}'));

    body.add(new JS.FunctionDeclaration(new JS.VariableDeclaration(name),
        node.functionExpression.accept(this)));

    if (isPublic(name)) _exports.add(name);
    return _statement(body);
  }

  JS.Method _emitTopLevelProperty(FunctionDeclaration node) {
    var name = node.name.name;
    if (isPublic(name)) _exports.add(name);
    return new JS.Method(
        new JS.PropertyName(name), node.functionExpression.accept(this),
        isGetter: node.isGetter, isSetter: node.isSetter);
  }

  @override
  JS.Expression visitFunctionExpression(FunctionExpression node) {
    var params = _visit(node.parameters);
    if (params == null) params = [];

    if (node.parent is FunctionDeclaration) {
      return new JS.Fun(params, node.body.accept(this));
    } else {
      var bindThis = _maybeBindThis(node.body);

      String code;
      AstNode body;
      var nodeBody = node.body;
      if (nodeBody is ExpressionFunctionBody) {
        code = '(#) => #';
        body = nodeBody.expression;
      } else {
        code = '(#) => { #; }';
        body = nodeBody;
      }
      return js.call('($code)$bindThis', [params, body.accept(this)]);
    }
  }

  @override
  JS.Statement visitFunctionDeclarationStatement(
      FunctionDeclarationStatement node) {
    var func = node.functionDeclaration;
    if (func.isGetter || func.isSetter) {
      return js.comment('Unimplemented function get/set statement: $node');
    }

    var name = new JS.VariableDeclaration(func.name.name);
    return new JS.Block([
      js.comment("// Function ${func.name.name}: ${func.element.type}\n"),
      new JS.FunctionDeclaration(name, func.functionExpression.accept(this))
    ]);
  }

  /// Writes a simple identifier. This can handle implicit `this` as well as
  /// going through the qualified library name if necessary.
  @override
  JS.Expression visitSimpleIdentifier(SimpleIdentifier node) {
    var e = node.staticElement;
    if (e == null) {
      return js.commentExpression(
          'Unimplemented unknown name', new JS.VariableUse(node.name));
    }
    var name = node.name;
    if (e.enclosingElement is CompilationUnitElement &&
        (e.library != libraryInfo.library || _needsModuleGetter(e))) {
      return js.call('#.#', [jsLibraryName(e.library), name]);
    } else if (currentClass != null && _needsImplicitThis(e)) {
      return js.call('this.#', name);
    }
    return new JS.VariableUse(name);
  }

  JS.Expression _emitTypeName(DartType type) {
    var name = type.name;
    var lib = type.element.library;
    if (name == '') {
      // TODO(jmesserly): remove when we're using coercion reifier.
      return _unimplementedCall('Unimplemented type $type');
    }

    var typeArgs = null;
    if (type is ParameterizedType) {
      // TODO(jmesserly): this is a workaround for an analyzer bug, see:
      // https://github.com/dart-lang/dart-dev-compiler/commit/a212d59ad046085a626dd8d16881cdb8e8b9c3fa
      if (type is! FunctionType || type.element is FunctionTypeAlias) {
        var args = type.typeArguments;
        if (args.any((a) => a != rules.provider.dynamicType)) {
          name = '$name\$';
          typeArgs = args.map(_emitTypeName);
        }
      }
    }

    JS.Expression result;
    if (lib != currentLibrary && lib != null) {
      result = js.call('#.#', [jsLibraryName(lib), name]);
    } else {
      result = new JS.VariableUse(name);
    }

    if (typeArgs != null) {
      result = js.call('#(#)', [result, typeArgs]);
    }
    return result;
  }

  @override
  JS.Node visitAssignmentExpression(AssignmentExpression node) {
    var lhs = node.leftHandSide;
    var rhs = node.rightHandSide;
    if (lhs is IndexExpression) {
      String code;
      var target = _getTarget(lhs);
      if (rules.isDynamicTarget(target)) {
        code = 'dart.dsetindex(#, #, #)';
      } else {
        code = '#.set(#, #)';
      }
      return js.call(code, [
        target.accept(this),
        lhs.index.accept(this),
        rhs.accept(this)
      ]);
    }

    if (lhs is PropertyAccess) {
      var target = _getTarget(lhs);
      if (rules.isDynamicTarget(target)) {
        return js.call('dart.dput(#, #, #)', [
          target.accept(this),
          js.string(lhs.propertyName.name, "'"),
          rhs.accept(this)
        ]);
      }
    }

    if (node.parent is ExpressionStatement &&
        rhs is CascadeExpression &&
        _isStateless(lhs, rhs)) {
      // Special case: cascade assignment to a variable in a statement.
      // We can reuse the variable to desugar it:
      //    result = []..length = length;
      // becomes:
      //    result = [];
      //    result.length = length;
      var savedCascadeTemp = _cascadeTarget;
      _cascadeTarget = lhs;

      var body = [];
      body.add(
          js.statement('# = #;', [lhs.accept(this), rhs.target.accept(this)]));
      for (var section in rhs.cascadeSections) {
        body.add(new JS.ExpressionStatement(section.accept(this)));
      }

      _cascadeTarget = savedCascadeTemp;
      return _statement(body);
    }

    return js.call('# = #', [lhs.accept(this), rhs.accept(this)]);
  }

  @override
  JS.Block visitExpressionFunctionBody(ExpressionFunctionBody node) {
    var initArgs = _emitArgumentInitializers(_parametersOf(node.parent));
    var ret = new JS.Return(node.expression.accept(this));
    return new JS.Block(initArgs != null ? [initArgs, ret] : [ret]);
  }

  @override
  JS.Block visitEmptyFunctionBody(EmptyFunctionBody node) => new JS.Block([]);

  @override
  JS.Block visitBlockFunctionBody(BlockFunctionBody node) {
    var initArgs = _emitArgumentInitializers(_parametersOf(node.parent));
    var block = visitBlock(node.block);
    if (initArgs != null) return new JS.Block([initArgs, block]);
    return block;
  }

  @override
  JS.Block visitBlock(Block node) => new JS.Block(_visitList(node.statements));

  @override
  JS.Expression visitMethodInvocation(MethodInvocation node) {
    var target = node.isCascaded ? _cascadeTarget : node.target;

    if (rules.isDynamicCall(node.methodName)) {
      var args = node.argumentList.accept(this);
      if (target != null) {
        return js.call('dart.dinvoke(#, #, #)', [
          target.accept(this),
          js.string(node.methodName.name, "'"),
          args
        ]);
      } else {
        return js.call(
            'dart.dinvokef(#, #)', [node.methodName.accept(this), args]);
      }
    }

    // TODO(jmesserly): if this resolves to a getter returning a function with
    // a call method, we don't generate the `.call` correctly.

    var targetJs;
    if (target != null) {
      targetJs = js.call('#.#', [target.accept(this), node.methodName.name]);
    } else {
      targetJs = node.methodName.accept(this);
    }

    return js.call('#(#)', [targetJs, node.argumentList.accept(this)]);
  }

  @override
  JS.Expression visitFunctionExpressionInvocation(
      FunctionExpressionInvocation node) {
    var code;
    if (rules.isDynamicCall(node.function)) {
      code = 'dart.dinvokef(#, #)';
    } else {
      code = '#(#)';
    }
    return js.call(
        code, [node.function.accept(this), node.argumentList.accept(this)]);
  }

  @override
  List<JS.Expression> visitArgumentList(ArgumentList node) {
    var args = <JS.Expression>[];
    var named = <JS.Property>[];
    for (var arg in node.arguments) {
      if (arg is NamedExpression) {
        named.add(visitNamedExpression(arg));
      } else {
        args.add(arg.accept(this));
      }
    }
    if (named.isNotEmpty) {
      args.add(new JS.ObjectInitializer(named));
    }
    return args;
  }

  @override
  JS.Property visitNamedExpression(NamedExpression node) {
    assert(node.parent is ArgumentList);
    return new JS.Property(new JS.PropertyName(node.name.label.name),
        node.expression.accept(this));
  }

  @override
  List<JS.Parameter> visitFormalParameterList(FormalParameterList node) {
    var result = <JS.Parameter>[];
    for (FormalParameter param in node.parameters) {
      if (param.kind == ParameterKind.NAMED) {
        result.add(new JS.Parameter(_jsNamedParameterName));
        break;
      }
      result.add(new JS.Parameter(param.identifier.name));
    }
    return result;
  }

  @override
  JS.Statement visitExpressionStatement(ExpressionStatement node) =>
      _expressionStatement(node.expression.accept(this));

  // Some expressions may choose to generate themselves as JS statements
  // if their parent is in a statement context.
  // TODO(jmesserly): refactor so we handle the special cases here, and
  // can use better return types on the expression visit methods.
  JS.Statement _expressionStatement(expr) =>
      expr is JS.Statement ? expr : new JS.ExpressionStatement(expr);

  @override
  JS.EmptyStatement visitEmptyStatement(EmptyStatement node) =>
      new JS.EmptyStatement();

  @override
  JS.Statement visitAssertStatement(AssertStatement node) =>
      // TODO(jmesserly): only emit in checked mode.
      js.statement('dart.assert(#);', node.condition.accept(this));

  @override
  JS.Return visitReturnStatement(ReturnStatement node) =>
      new JS.Return(_visit(node.expression));

  @override
  visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    var body = <JS.Statement>[];

    for (var field in node.variables.variables) {
      if (field.isConst) {
        // constant fields don't change, so we can generate them as `let`
        // but add them to the module's exports
        var name = field.name.name;
        body.add(js.statement('let # = #;', [
          new JS.VariableDeclaration(name),
          _visitInitializer(field)
        ]));
        if (isPublic(name)) _exports.add(name);
      } else if (_isFieldInitConstant(field)) {
        body.add(js.statement(
            '# = #;', [field.name.accept(this), _visitInitializer(field)]));
      } else {
        _lazyFields.add(field);
      }
    }

    return _statement(body);
  }

  @override
  visitVariableDeclarationList(VariableDeclarationList node) {
    var last = node.variables.last;
    var lastInitializer = last.initializer;

    List<JS.VariableInitialization> variables;
    if (lastInitializer is CascadeExpression &&
        node.parent is VariableDeclarationStatement) {
      // Special case: cascade as variable initializer
      //
      // We can reuse the variable to desugar it:
      //    var result = []..length = length;
      // becomes:
      //    var result = [];
      //    result.length = length;
      var savedCascadeTemp = _cascadeTarget;
      _cascadeTarget = last.name;

      variables = _visitList(node.variables.take(node.variables.length - 1));
      variables.add(new JS.VariableInitialization(
          new JS.VariableDeclaration(last.name.name),
          lastInitializer.target.accept(this)));

      var result = <JS.Expression>[
        new JS.VariableDeclarationList('let', variables)
      ];
      result.addAll(_visitList(lastInitializer.cascadeSections));
      _cascadeTarget = savedCascadeTemp;
      return _statement(result.map((e) => new JS.ExpressionStatement(e)));
    } else {
      variables = _visitList(node.variables);
    }

    return new JS.VariableDeclarationList('let', variables);
  }

  @override
  JS.VariableInitialization visitVariableDeclaration(VariableDeclaration node) {
    var name = new JS.VariableDeclaration(node.name.name);
    return new JS.VariableInitialization(name, _visitInitializer(node));
  }

  JS.Expression _visitInitializer(VariableDeclaration node) {
    var value = _visit(node.initializer);
    // explicitly initialize to null, to avoid getting `undefined`.
    // TODO(jmesserly): do this only for vars that aren't definitely assigned.
    return value != null ? value : new JS.LiteralNull();
  }

  void _flushLazyFields(List<JS.Statement> body) {
    var code = _emitLazyFields(_libraryName, _lazyFields);
    if (code != null) body.add(code);
    _lazyFields.clear();
  }

  JS.Statement _emitLazyFields(
      String objExpr, List<VariableDeclaration> fields) {
    if (fields.isEmpty) return null;

    var methods = [];
    for (var node in fields) {
      var name = node.name.name;
      methods.add(new JS.Method(new JS.PropertyName(name),
          js.call('function() { return #; }', node.initializer.accept(this)),
          isGetter: true));

      // TODO(jmesserly): use a dummy setter to indicate writable.
      if (!node.isFinal) {
        methods.add(new JS.Method(
            new JS.PropertyName(name), js.call('function() {}'),
            isSetter: true));
      }
    }

    return js.statement(
        'dart.defineLazyProperties(#, { # })', [objExpr, methods]);
  }

  void _flushLibraryProperties(List<JS.Statement> body) {
    if (_properties.isEmpty) return;
    body.add(js.statement('dart.copyProperties(#, { # });', [
      _libraryName,
      _properties.map(_emitTopLevelProperty)
    ]));
    _properties.clear();
  }

  @override
  JS.Statement visitVariableDeclarationStatement(
          VariableDeclarationStatement node) =>
      _expressionStatement(node.variables.accept(this));

  @override
  visitConstructorName(ConstructorName node) {
    var typeName = node.type.name.accept(this);
    if (node.name != null) {
      return js.call('#.#', [typeName, node.name.name]);
    }
    return typeName;
  }

  @override
  visitInstanceCreationExpression(InstanceCreationExpression node) {
    return js.call('new #(#)', [
      node.constructorName.accept(this),
      node.argumentList.accept(this)
    ]);
  }

  /// True if this type is built-in to JS, and we use the values unwrapped.
  /// For these types we generate a calling convention via static
  /// "extension methods". This allows types to be extended without adding
  /// extensions directly on the prototype.
  bool _isJSBuiltinType(DartType t) =>
      rules.isNumType(t) || rules.isStringType(t) || rules.isBoolType(t);

  bool typeIsPrimitiveInJS(DartType t) => !rules.isDynamic(t) &&
      (rules.isIntType(t) ||
          rules.isDoubleType(t) ||
          rules.isBoolType(t) ||
          rules.isNumType(t));

  bool typeIsNonNullablePrimitiveInJS(DartType t) =>
      typeIsPrimitiveInJS(t) && rules.isNonNullableType(t);

  bool binaryOperationIsPrimitive(DartType leftT, DartType rightT) =>
      typeIsPrimitiveInJS(leftT) && typeIsPrimitiveInJS(rightT);

  bool unaryOperationIsPrimitive(DartType t) => typeIsPrimitiveInJS(t);

  JS.Expression notNull(Expression expr) {
    var type = rules.getStaticType(expr);
    if (rules.isNonNullableType(type)) {
      return expr.accept(this);
    } else {
      return js.call('dart.notNull(#)', expr.accept(this));
    }
  }

  @override
  JS.Expression visitBinaryExpression(BinaryExpression node) {
    var op = node.operator;
    var left = node.leftOperand;
    var right = node.rightOperand;
    var leftType = rules.getStaticType(left);
    var rightType = rules.getStaticType(right);

    var code;
    if (op.type.isEqualityOperator) {
      // If we statically know LHS or RHS is null we can generate a clean check.
      // We can also do this if the left hand side is a primitive type, because
      // we know then it doesn't have an overridden.
      if (_isNull(left) || _isNull(right) || typeIsPrimitiveInJS(leftType)) {
        // https://people.mozilla.org/~jorendorff/es6-draft.html#sec-strict-equality-comparison
        code = op.type == TokenType.EQ_EQ ? '# === #' : '# !== #';
      } else {
        var bang = op.type == TokenType.BANG_EQ ? '!' : '';
        code = '${bang}dart.equals(#, #)';
      }
      return js.call(code, [left.accept(this), right.accept(this)]);
    } else if (binaryOperationIsPrimitive(leftType, rightType)) {
      // special cases where we inline the operation
      // these values are assumed to be non-null (determined by the checker)
      // TODO(jmesserly): it would be nice to just inline the method from core,
      // instead of special cases here.
      if (op.type == TokenType.TILDE_SLASH) {
        // `a ~/ b` is equivalent to `(a / b).truncate()`
        code = '(# / #).truncate()';
      } else {
        // TODO(vsm): When do Dart ops not map to JS?
        code = '# $op #';
      }
      return js.call(code, [notNull(left), notNull(right)]);
    } else {
      var opString = js.string(op.lexeme, "'");
      if (rules.isDynamicTarget(left)) {
        // dynamic dispatch
        return js.call('dart.dbinary(#, #, #)', [
          left.accept(this),
          opString,
          right.accept(this)
        ]);
      } else if (_isJSBuiltinType(leftType)) {
        // TODO(jmesserly): we'd get better readability from the static-dispatch
        // pattern below. Consider:
        //
        //     "hello"['+']"world"
        // vs
        //     core.String['+']("hello", "world")
        //
        // Infix notation is much more readable, which is a bit part of why
        // C# added its extension methods feature. However this would require
        // adding these methods to String.prototype/Number.prototype in JS.
        return js.call('#.#(#, #)', [
          _emitTypeName(leftType),
          opString,
          left.accept(this),
          right.accept(this)
        ]);
      } else {
        // Generic static-dispatch, user-defined operator code path.
        return js.call(
            '#.#(#)', [left.accept(this), opString, right.accept(this)]);
      }
    }
  }

  bool _isNull(Expression expr) => expr is NullLiteral;

  @override
  JS.Expression visitPostfixExpression(PostfixExpression node) {
    var op = node.operator;
    var expr = node.operand;

    var dispatchType = rules.getStaticType(expr);
    if (unaryOperationIsPrimitive(dispatchType)) {
      // TODO(vsm): When do Dart ops not map to JS?
      return js.call('#$op', notNull(expr));
    } else {
      // TODO(vsm): Figure out operator calling convention / dispatch.
      return visitExpression(node);
    }
  }

  @override
  JS.Expression visitPrefixExpression(PrefixExpression node) {
    var op = node.operator;
    var expr = node.operand;

    var dispatchType = rules.getStaticType(expr);
    if (unaryOperationIsPrimitive(dispatchType)) {
      // TODO(vsm): When do Dart ops not map to JS?
      return js.call('$op#', notNull(expr));
    } else {
      // TODO(vsm): Figure out operator calling convention / dispatch.
      return visitExpression(node);
    }
  }

  // Cascades can contain [IndexExpression], [MethodInvocation] and
  // [PropertyAccess]. The code generation for those is handled in their
  // respective visit methods.
  @override
  JS.Node visitCascadeExpression(CascadeExpression node) {
    var savedCascadeTemp = _cascadeTarget;

    var parent = node.parent;
    JS.Node result;
    if (_isStateless(node.target, node)) {
      // Special case: target is stateless, so we can just reuse it.
      _cascadeTarget = node.target;

      if (parent is ExpressionStatement) {
        var sections = _visitList(node.cascadeSections);
        result = _statement(sections.map((e) => new JS.ExpressionStatement(e)));
      } else {
        // Use comma expression. For example:
        //    (sb.write(1), sb.write(2), sb)
        var sections = _visitListToBinary(node.cascadeSections, ',');
        result = new JS.Binary(',', sections, _cascadeTarget.accept(this));
      }
    } else {
      // In the general case we need to capture the target expression into
      // a temporary. This uses a lambda to get a temporary scope, and it also
      // remains valid in an expression context.
      // TODO(jmesserly): need a better way to handle temps.
      // TODO(jmesserly): special case for parent is ExpressionStatement?
      _cascadeTarget =
          new SimpleIdentifier(new StringToken(TokenType.IDENTIFIER, '_', 0));
      _cascadeTarget.staticElement =
          new LocalVariableElementImpl.forNode(_cascadeTarget);
      _cascadeTarget.staticType = node.target.staticType;

      var body = _visitList(node.cascadeSections);
      if (node.parent is! ExpressionStatement) {
        body.add(js.statement('return #;', _cascadeTarget.name));
      }

      var bindThis = _maybeBindThis(node.cascadeSections);
      result = js.call('((#) => { # })$bindThis(#)', [
        _cascadeTarget.name,
        body,
        node.target.accept(this)
      ]);
    }

    _cascadeTarget = savedCascadeTemp;
    return result;
  }

  /// True is the expression can be evaluated multiple times without causing
  /// code execution. This is true for final fields. This can be true for local
  /// variables, if:
  /// * they are not assigned within the [context].
  /// * they are not assigned in a function closure anywhere.
  bool _isStateless(Expression node, [AstNode context]) {
    if (node is SimpleIdentifier) {
      var e = node.staticElement;
      if (e is PropertyAccessorElement) e = e.variable;
      if (e is VariableElementImpl && !e.isSynthetic) {
        if (e.isFinal) return true;
        if (e is LocalVariableElementImpl || e is ParameterElementImpl) {
          // make sure the local isn't mutated in the context.
          return !_isPotentiallyMutated(e, context);
        }
      }
    }
    return false;
  }

  @override
  visitParenthesizedExpression(ParenthesizedExpression node) =>
      // The printer handles precedence so we don't need to.
      node.expression.accept(this);

  @override
  visitSimpleFormalParameter(SimpleFormalParameter node) =>
      node.identifier.accept(this);

  @override
  visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) =>
      node.identifier.accept(this);

  @override
  JS.This visitThisExpression(ThisExpression node) => new JS.This();

  @override
  JS.Super visitSuperExpression(SuperExpression node) => new JS.Super();

  @override
  visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.prefix.staticElement is PrefixElement) {
      return node.identifier.accept(this);
    } else {
      return _visitGet(node.prefix, node.identifier);
    }
  }

  @override
  visitPropertyAccess(PropertyAccess node) =>
      _visitGet(_getTarget(node), node.propertyName);

  /// Shared code for [PrefixedIdentifier] and [PropertyAccess].
  _visitGet(Expression target, SimpleIdentifier name) {
    if (rules.isDynamicTarget(target)) {
      return js.call(
          'dart.dload(#, #)', [target.accept(this), js.string(name.name, "'")]);
    } else {
      return js.call('#.#', [target.accept(this), name.name]);
    }
  }

  @override
  visitIndexExpression(IndexExpression node) {
    var target = _getTarget(node);
    var code;
    if (rules.isDynamicTarget(target)) {
      code = 'dart.dindex(#, #)';
    } else {
      code = '#.get(#)';
    }
    return js.call(code, [target.accept(this), node.index.accept(this)]);
  }

  /// Gets the target of a [PropertyAccess] or [IndexExpression].
  /// Those two nodes are special because they're both allowed on left side of
  /// an assignment expression and cascades.
  Expression _getTarget(node) {
    assert(node is IndexExpression || node is PropertyAccess);
    return node.isCascaded ? _cascadeTarget : node.target;
  }

  @override
  visitConditionalExpression(ConditionalExpression node) {
    return js.call('# ? # : #', [
      node.condition.accept(this),
      node.thenExpression.accept(this),
      node.elseExpression.accept(this)
    ]);
  }

  @override
  visitThrowExpression(ThrowExpression node) {
    var expr = node.expression.accept(this);
    if (node.parent is ExpressionStatement) {
      return js.statement('throw #;', expr);
    } else {
      return js.call('dart.throw_(#)', expr);
    }
  }

  @override
  JS.If visitIfStatement(IfStatement node) {
    return new JS.If(node.condition.accept(this), _visit(node.thenStatement),
        _visitOrEmpty(node.elseStatement));
  }

  @override
  JS.For visitForStatement(ForStatement node) {
    var init = _visit(node.initialization);
    if (init == null) init = _visit(node.variables);
    return new JS.For(init, _visit(node.condition),
        _visitListToBinary(node.updaters, ','), _visit(node.body));
  }

  @override
  JS.While visitWhileStatement(WhileStatement node) {
    return new JS.While(node.condition.accept(this), node.body.accept(this));
  }

  @override
  JS.Do visitDoStatement(DoStatement node) {
    return new JS.Do(node.body.accept(this), node.condition.accept(this));
  }

  @override
  JS.ForOf visitForEachStatement(ForEachStatement node) {
    var init = _visit(node.identifier);
    if (init == null) {
      init = js.call('let #', node.loopVariable.identifier.name);
    }
    return new JS.ForOf(
        init, node.iterable.accept(this), node.body.accept(this));
  }

  @override
  visitBreakStatement(BreakStatement node) {
    var label = node.label;
    return new JS.Break(label != null ? label.name : null);
  }

  @override
  visitContinueStatement(ContinueStatement node) {
    var label = node.label;
    return new JS.Continue(label != null ? label.name : null);
  }

  @override
  visitTryStatement(TryStatement node) {
    return new JS.Try(_visit(node.body), _visitCatch(node.catchClauses),
        _visit(node.finallyBlock));
  }

  _visitCatch(NodeList<CatchClause> clauses) {
    if (clauses == null || clauses.isEmpty) return null;

    // TODO(jmesserly): need a better way to get a temporary variable.
    // This could incorrectly shadow a user's name.
    var name = '\$e';

    if (clauses.length == 1) {
      // Special case for a single catch.
      var clause = clauses.single;
      if (clause.exceptionParameter != null) {
        name = clause.exceptionParameter.name;
      }
    }

    var catchBody = _statement(clauses.map((c) => _visitCatchClause(c, name)));

    return new JS.Catch(new JS.VariableDeclaration(name), catchBody);
  }

  JS.Statement _statement(Iterable stmts) {
    var s = stmts is List ? stmts : new List<JS.Statement>.from(stmts);
    // TODO(jmesserly): empty block singleton?
    if (s.length == 0) return new JS.Block([]);
    if (s.length == 1) return s[0];
    return new JS.Block(s);
  }

  JS.Statement _visitCatchClause(CatchClause node, String varName) {
    var body = [];
    if (node.catchKeyword != null) {
      var name = node.exceptionParameter;
      if (name != null && name.name != varName) {
        body.add(js.statement('let # = #;', [name.accept(this), varName]));
      }
      if (node.stackTraceParameter != null) {
        var stackVar = node.stackTraceParameter.name;
        body.add(js.statement(
            'let # = dart.stackTrace(#);', [stackVar, name.accept(this)]));
      }
    }

    body.add(node.body.accept(this));

    if (node.exceptionType != null) {
      return js.statement('if (dart.is(#, #)) #;', [
        varName,
        _emitTypeName(node.exceptionType.type),
        _statement(body)
      ]);
    }
    return _statement(body);
  }

  @override
  JS.Case visitSwitchCase(SwitchCase node) {
    var expr = node.expression.accept(this);
    var body = _visitList(node.statements);
    if (node.labels.isNotEmpty) {
      body.insert(0, js.comment('Unimplemented case labels: ${node.labels}'));
    }
    // TODO(jmesserly): make sure we are statically checking fall through
    return new JS.Case(expr, new JS.Block(body));
  }

  @override
  JS.Default visitSwitchDefault(SwitchDefault node) {
    var body = _visitList(node.statements);
    if (node.labels.isNotEmpty) {
      body.insert(0, js.comment('Unimplemented case labels: ${node.labels}'));
    }
    // TODO(jmesserly): make sure we are statically checking fall through
    return new JS.Default(new JS.Block(body));
  }

  @override
  JS.Switch visitSwitchStatement(SwitchStatement node) =>
      new JS.Switch(node.expression.accept(this), _visitList(node.members));

  @override
  JS.Statement visitLabeledStatement(LabeledStatement node) {
    var result = _visit(node.statement);
    for (var label in node.labels.reversed) {
      result = new JS.LabeledStatement(label.label.name, result);
    }
    return result;
  }

  @override
  visitIntegerLiteral(IntegerLiteral node) => js.number(node.value);

  @override
  visitDoubleLiteral(DoubleLiteral node) => js.number(node.value);

  @override
  visitNullLiteral(NullLiteral node) => new JS.LiteralNull();

  @override
  visitListLiteral(ListLiteral node) {
    // TODO(jmesserly): make this faster. We're wasting an array.
    var list = js.call('new List.from(#)', [
      new JS.ArrayInitializer(_visitList(node.elements))
    ]);
    if (node.constKeyword != null) {
      list = js.commentExpression('Unimplemented const', list);
    }
    return list;
  }

  @override
  visitMapLiteral(MapLiteral node) {
    var entries = node.entries;
    var mapArguments = null;
    if (entries.isEmpty) return js.call('dart.map()');

    // Use JS object literal notation if possible, otherwise use an array.
    if (entries.every((e) => e.key is SimpleStringLiteral)) {
      var props = [];
      for (var e in entries) {
        var key = (e.key as SimpleStringLiteral).value;
        var value = e.value.accept(this);
        props.add(new JS.Property(js.escapedString(key), value));
      }
      mapArguments = new JS.ObjectInitializer(props);
    } else {
      var values = [];
      for (var e in entries) {
        values.add(e.key.accept(this));
        values.add(e.value.accept(this));
      }
      mapArguments = new JS.ArrayInitializer(values);
    }
    return js.call('dart.map(#)', [mapArguments]);
  }

  @override
  JS.LiteralString visitSimpleStringLiteral(SimpleStringLiteral node) =>
      js.escapedString(node.value, node.isSingleQuoted ? "'" : '"');

  @override
  JS.Expression visitAdjacentStrings(AdjacentStrings node) =>
      _visitListToBinary(node.strings, '+');

  @override
  JS.TemplateString visitStringInterpolation(StringInterpolation node) {
    // Assuming we implement toString() on our objects, we can avoid calling it
    // in most cases. Builtin types may differ though. We could handle this with
    // a tagged template.
    return new JS.TemplateString(_visitList(node.elements));
  }

  @override
  String visitInterpolationString(InterpolationString node) {
    // TODO(jmesserly): this call adds quotes, and then we strip them off.
    var str = js.escapedString(node.value, '`').value;
    return str.substring(1, str.length - 1);
  }

  @override
  visitInterpolationExpression(InterpolationExpression node) =>
      node.expression.accept(this);

  @override
  visitBooleanLiteral(BooleanLiteral node) => js.boolean(node.value);

  @override
  JS.Statement visitDeclaration(Declaration node) =>
      js.comment('Unimplemented ${node.runtimeType}: $node');

  @override
  JS.Statement visitStatement(Statement node) =>
      js.comment('Unimplemented ${node.runtimeType}: $node');

  @override
  JS.Expression visitExpression(Expression node) =>
      _unimplementedCall('Unimplemented ${node.runtimeType}: $node');

  JS.Expression _unimplementedCall(String comment) {
    return js.call('dart.throw_(#)', [js.escapedString(comment)]);
  }

  @override
  visitNode(AstNode node) {
    // TODO(jmesserly): verify this is unreachable.
    throw 'Unimplemented ${node.runtimeType}: $node';
  }

  // TODO(jmesserly): this is used to determine if the field initialization is
  // side effect free. We should make the check more general, as things like
  // list/map literals/regexp are also side effect free and fairly common
  // to use as field initializers.
  bool _isFieldInitConstant(VariableDeclaration field) =>
      field.initializer == null || _computeConstant(field).isValid;

  EvaluationResult _computeConstant(VariableDeclaration field) {
    // If the constant is already computed by ConstantEvaluator, just return it.
    VariableElementImpl element = field.element;
    var result = element.evaluationResult;
    if (result != null) return result;

    // ConstantEvaluator will not compute constants for non-const fields
    // at least for cases like `int x = 0;`, so run ConstantVisitor for those.
    // TODO(jmesserly): ideally we'd only do this if we're sure it was skipped
    // by ConstantEvaluator.
    var initializer = field.initializer;
    if (initializer == null) return null;

    return _constEvaluator.evaluate(initializer);
  }

  /// Returns true if [element] is a getter in JS, therefore needs
  /// `lib.topLevel` syntax instead of just `topLevel`.
  bool _needsModuleGetter(Element element) {
    if (element is PropertyAccessorElement) {
      element = (element as PropertyAccessorElement).variable;
    }
    return element is TopLevelVariableElement && !element.isConst;
  }

  _visit(AstNode node) => node != null ? node.accept(this) : null;

  JS.Statement _visitOrEmpty(AstNode node) {
    if (node == null) return new JS.EmptyStatement();
    return node.accept(this);
  }

  List _visitList(Iterable<AstNode> nodes) {
    if (nodes == null) return null;
    var result = [];
    for (var node in nodes) result.add(node.accept(this));
    return result;
  }

  /// Visits a list of expressions, creating a comma expression if needed in JS.
  JS.Expression _visitListToBinary(List<Expression> nodes, String operator) {
    if (nodes == null || nodes.isEmpty) return null;

    JS.Expression result = null;
    for (var node in nodes) {
      var jsExpr = node.accept(this);
      if (result == null) {
        result = jsExpr;
      } else {
        result = new JS.Binary(operator, result, jsExpr);
      }
    }
    return result;
  }

  /// The following names are allowed for user-defined operators:
  ///
  ///     <, >, <=, >=, ==, -, +, /, ˜/, *, %, |, ˆ, &, <<, >>, []=, [], ˜
  ///
  /// For the indexing operators, we use `get` and `set` instead:
  ///
  ///     x.get('hi')
  ///     x.set('hi', 123)
  ///
  /// This follows the same pattern as EcmaScript 6 Map:
  /// <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Map>
  ///
  /// For all others we use the operator name:
  ///
  ///     x['+'](y)
  ///
  /// Equality is a bit special, it is generated via the Dart `equals` runtime
  /// helper, that checks for null. The user defined method is called '=='.
  String _jsMethodName(String name) {
    if (name == '[]') return 'get';
    if (name == '[]=') return 'set';
    return name;
  }

  bool _externalOrNative(node) =>
      node.externalKeyword != null || _functionBody(node) is NativeFunctionBody;

  FunctionBody _functionBody(node) =>
      node is FunctionDeclaration ? node.functionExpression.body : node.body;

  String _maybeBindThis(node) {
    if (currentClass == null) return '';
    var visitor = _BindThisVisitor._instance;
    visitor._bindThis = false;
    node.accept(visitor);
    return visitor._bindThis ? '.bind(this)' : '';
  }

  static bool _needsImplicitThis(Element e) =>
      e is PropertyAccessorElement && !e.variable.isStatic ||
          e is ClassMemberElement && !e.isStatic && e is! ConstructorElement;
}

/// Returns true if the local variable is potentially mutated within [context].
/// This accounts for closures that may have been created outside of [context].
bool _isPotentiallyMutated(VariableElementImpl e, [AstNode context]) {
  if (e.isPotentiallyMutatedInClosure) {
    // TODO(jmesserly): this returns true incorrectly in some cases, because
    // VariableResolverVisitor only checks that enclosingElement is not the
    // function element, but enclosingElement can be something else in some
    // cases (the block scope?). So it's more conservative than it could be.
    return true;
  }
  if (e.isPotentiallyMutatedInScope) {
    // Need to visit the context looking for assignment to this local.
    if (context != null) {
      var visitor = new _AssignmentFinder(e);
      context.accept(visitor);
      return visitor._potentiallyMutated;
    }
    return true;
  }
  return false;
}

/// Adapted from VariableResolverVisitor. Finds an assignment to a given
/// local variable.
class _AssignmentFinder extends RecursiveAstVisitor {
  final VariableElementImpl _variable;
  bool _potentiallyMutated = false;

  _AssignmentFinder(this._variable);

  @override
  visitSimpleIdentifier(SimpleIdentifier node) {
    // Ignore if qualified.
    AstNode parent = node.parent;
    if (parent is PrefixedIdentifier &&
        identical(parent.identifier, node)) return;
    if (parent is PropertyAccess &&
        identical(parent.propertyName, node)) return;
    if (parent is MethodInvocation &&
        identical(parent.methodName, node)) return;
    if (parent is ConstructorName) return;
    if (parent is Label) return;

    if (node.inSetterContext() && node.staticElement == _variable) {
      _potentiallyMutated = true;
    }
  }
}

/// This is a workaround for V8 arrow function bindings being not yet
/// implemented. See issue #43
class _BindThisVisitor extends RecursiveAstVisitor {
  static _BindThisVisitor _instance = new _BindThisVisitor();
  bool _bindThis = false;

  @override
  visitSimpleIdentifier(SimpleIdentifier node) {
    if (JSCodegenVisitor._needsImplicitThis(node.staticElement)) {
      _bindThis = true;
    }
  }

  @override
  visitThisExpression(ThisExpression node) {
    _bindThis = true;
  }
}

class JSGenerator extends CodeGenerator {
  JSGenerator(String outDir, Uri root, TypeRules rules)
      : super(outDir, root, rules);

  void generateLibrary(Iterable<CompilationUnit> units, LibraryInfo info,
      CheckerReporter reporter) {
    JS.Block jsTree =
        new JSCodegenVisitor(info, rules).generateLibrary(units, reporter);

    var outputPath = path.join(outDir, jsOutputPath(info));
    new Directory(path.dirname(outputPath)).createSync(recursive: true);

    var context = new JS.SimpleJavaScriptPrintingContext();
    var opts =
        new JS.JavaScriptPrintingOptions(avoidKeywordsInIdentifiers: true);
    var printer = new JS.Printer(opts, context);
    printer.blockOutWithoutBraces(jsTree);
    new File(outputPath).writeAsStringSync(context.getText());
  }
}

/// Choose a canonical name from the library element.
/// This never uses the library's name (the identifier in the `library`
/// declaration) as it doesn't have any meaningful rules enforced.
String jsLibraryName(LibraryElement library) => canonicalLibraryName(library);

/// Path to file that will be generated for [info].
// TODO(jmesserly): library directory should be relative to its package
// root. For example, "package:dev_compiler/src/codegen/js_codegen.dart" would be:
// "ddc/src/codegen/js_codegen.js" under the output directory.
String jsOutputPath(LibraryInfo info) => '${info.name}/${info.name}.js';
