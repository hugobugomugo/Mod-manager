import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import '../services/api_service.dart';
import '../services/mod_manager_service.dart';

// API Service Provider
final modManagerServiceProvider = FutureProvider<ModManagerService>((ref) async {
  return await ApiService.getModManagerService();
});

class _DoubleNotifier extends Notifier<double> {
  final double _initial;
  _DoubleNotifier(this._initial);
  @override
  double build() => _initial;
}

class _IntNotifier extends Notifier<int> {
  final int _initial;
  _IntNotifier(this._initial);
  @override
  int build() => _initial;
}

class _BoolNotifier extends Notifier<bool> {
  final bool _initial;
  _BoolNotifier(this._initial);
  @override
  bool build() => _initial;
}

class _StringNotifier extends Notifier<String> {
  final String _initial;
  _StringNotifier(this._initial);
  @override
  String build() => _initial;
}

class _CharactersNotifier extends Notifier<List<CharacterInfo>> {
  @override
  List<CharacterInfo> build() => [];
}

class _ModsNotifier extends Notifier<List<ModInfo>> {
  @override
  List<ModInfo> build() => [];
}

class _LocaleNotifier extends Notifier<Locale> {
  @override
  Locale build() => const Locale('en');
}

enum ActivationMode { single, multi }

class _ActivationModeNotifier extends Notifier<ActivationMode> {
  @override
  ActivationMode build() => ActivationMode.single;
}

// Zoom scale provider
final zoomScaleProvider = NotifierProvider<_DoubleNotifier, double>(
  () => _DoubleNotifier(1.0),
);

// Tab index provider
final tabIndexProvider = NotifierProvider<_IntNotifier, int>(
  () => _IntNotifier(0),
);

// Characters list
final charactersProvider = NotifierProvider<_CharactersNotifier, List<CharacterInfo>>(
  _CharactersNotifier.new,
);

// Selected character index
final selectedCharacterIndexProvider = NotifierProvider<_IntNotifier, int>(
  () => _IntNotifier(0),
);

// Current mods list (all mods)
final modsProvider = NotifierProvider<_ModsNotifier, List<ModInfo>>(
  _ModsNotifier.new,
);

// Search query provider
final searchQueryProvider = NotifierProvider<_StringNotifier, String>(
  () => _StringNotifier(''),
);

// Filtered characters based on search - optimized with select
final filteredCharactersProvider = Provider<List<CharacterInfo>>((ref) {
  final characters = ref.watch(charactersProvider);
  final query = ref.watch(searchQueryProvider);

  if (query.isEmpty) {
    return characters;
  }

  final lowerQuery = query.toLowerCase();
  return characters.where((character) {
    return character.name.toLowerCase().contains(lowerQuery) ||
        character.id.toLowerCase().contains(lowerQuery);
  }).toList();
});

// Skins for selected character - optimized
final currentCharacterSkinsProvider = Provider<List<ModInfo>>((ref) {
  final characters = ref.watch(charactersProvider);
  final selectedIndex = ref.watch(selectedCharacterIndexProvider);

  if (characters.isEmpty || selectedIndex < 0 || selectedIndex >= characters.length) {
    return const [];
  }

  return characters[selectedIndex].skins;
});

// Theme mode provider (dark/light)
final isDarkModeProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(true),
);

// Settings providers
final modsPathProvider = NotifierProvider<_StringNotifier, String>(
  () => _StringNotifier(''),
);
final autoRefreshProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(false),
);

// View mode: grid or carousel
final isGridViewProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(true),
);

// Locale provider for localization
final localeProvider = NotifierProvider<_LocaleNotifier, Locale>(
  _LocaleNotifier.new,
);

// Activation mode: single or multi
final activationModeProvider = NotifierProvider<_ActivationModeNotifier, ActivationMode>(
  _ActivationModeNotifier.new,
);

// Sidebar collapsed state
final sidebarCollapsedProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(false),
);

// Auto F10 reload toggle (green = enabled, red = disabled)
final autoF10ReloadProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(false),
);

// "all mods off" kill switch - stores which mods were active before disabling
class _StringListNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => [];
}

final allModsDisabledProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(false),
);

final savedActiveModsProvider = NotifierProvider<_StringListNotifier, List<String>>(
  _StringListNotifier.new,
);
