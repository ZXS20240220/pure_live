import 'package:flutter/material.dart';

bool isEditingFocused() {
  final primary = FocusManager.instance.primaryFocus;
  if (primary == null) return false;
  final context = primary.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}
