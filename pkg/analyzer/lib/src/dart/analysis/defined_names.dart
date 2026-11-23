// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/src/dart/ast/ast.dart';

/// Returns the names of class members declared in [unit].
Set<String> computeDefinedClassMemberNames(CompilationUnitImpl unit) {
  var names = <String>{};

  void addName(Token? token) {
    var lexeme = token?.lexeme;
    if (lexeme != null && lexeme.isNotEmpty) {
      names.add(lexeme);
    }
  }

  void addMember(MemberDeclarationImpl member) {
    if (member is MethodDeclarationV1OriginImpl) {
      addName(member.nameToken);
    } else if (member is FieldsDeclarationImpl) {
      for (var field in member.fields) {
        addName(field.name);
      }
    }
  }

  void addDeclaringParameters(ClassNamePartImpl namePart) {
    if (namePart is PrimaryConstructorDeclarationImpl) {
      for (var parameter in namePart.declaringFormalParameters) {
        addName(parameter.name);
      }
    }
  }

  for (var declaration in unit.declarations2) {
    switch (declaration) {
      case ClassDeclaration2Impl(:var namePart, :var body) ||
          ExtensionTypeDeclaration2Impl(:var namePart, :var body):
        addDeclaringParameters(namePart);
        body.members.forEach(addMember);
      case EnumDeclaration2Impl(:var namePart, :var body):
        addDeclaringParameters(namePart);
        for (var constant in body.constants) {
          addName(constant.name);
        }
        body.members.forEach(addMember);
      case ExtensionDeclaration2Impl(:var body) ||
          MixinDeclaration2Impl(:var body):
        body.members.forEach(addMember);
      case ClassTypeAlias2Impl() ||
          FunctionTypeAlias2Impl() ||
          GenericTypeAlias2Impl() ||
          TopLevelFunctionDeclarationImpl() ||
          TopLevelGetterDeclarationImpl() ||
          TopLevelSetterDeclarationImpl() ||
          TopLevelVariablesDeclarationImpl():
        break;
    }
  }

  return names;
}
