import 'dart:ui';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import 'config_service.dart';
import 'mod_manager_service.dart';

class ApiService {
  static ModManagerService? _modManager;
  static ConfigService? _configService;
  static ProviderContainer? _container;

  static Future<void> initialize({ProviderContainer? container}) async {
    if (_configService == null) {
      final prefs = await SharedPreferences.getInstance();
      _configService = ConfigService(prefs);
      await _configService!.loadFromFile();
    }

    if (container != null) {
      _container = container;
      final localeCode = _configService?.language ?? 'en';
      _container!.read(localeProvider.notifier).state = Locale(localeCode);
    }

    if (_modManager == null) {
      _modManager = ModManagerService(_configService!, _container!);
    }
  }

  static Future<List<ModInfo>> getMods() async {
    try {
      await initialize();
      return await _modManager!.getModsInfo();
    } catch (e) {
      throw Exception('getMods error: $e');
    }
  }

  static Future<bool> toggleMod(String modId, {bool? currentlyActive}) async {
    try {
      await initialize();
      if (currentlyActive != null) {
        return currentlyActive
            ? await _modManager!.deactivateMod(modId)
            : await _modManager!.activateMod(modId);
      }
      return await _modManager!.toggleMod(modId);
    } catch (e) {
      throw Exception('toggleMod error: $e');
    }
  }

  static Future<bool> toggleModForCharacter(
    String modId,
    String characterId,
    List<ModInfo> characterSkins,
    {bool multiMode = false}
  ) async {
    try {
      await initialize();
      final currentMod = characterSkins.firstWhere((mod) => mod.id == modId);

      if (currentMod.isActive) {
        return await _modManager!.deactivateMod(modId);
      }

      // single mode: deactivate all other active skins for this character
      if (!multiMode) {
        for (final skin in characterSkins) {
          if (skin.isActive && skin.id != modId) {
            await _modManager!.deactivateMod(skin.id);
          }
        }
      }

      return await _modManager!.activateMod(modId);
    } catch (e) {
      throw Exception('toggleModForCharacter error: $e');
    }
  }

  static Future<String> clearAll() async {
    try {
      await initialize();
      final mods = await _modManager!.getModsInfo();
      int deactivated = 0;
      for (final mod in mods) {
        if (mod.isActive) {
          await _modManager!.deactivateMod(mod.id);
          deactivated++;
        }
      }
      return 'Deactivated $deactivated mods';
    } catch (e) {
      throw Exception('clearAll error: $e');
    }
  }

  static Future<Map<String, String>> getConfig() async {
    try {
      await initialize();
      return {
        'mods_path': _configService!.modsPath ?? '',
        'save_mods_path': _configService!.saveModsPath ?? '',
        'language': _configService!.language,
      };
    } catch (e) {
      throw Exception('getConfig error: $e');
    }
  }

  static Future<void> setLanguage(String languageCode) async {
    await initialize();
    await _configService!.setLanguage(languageCode);
    _container?.read(localeProvider.notifier).state = Locale(languageCode);
  }

  static Future<String> updateConfig({
    required String modsPath,
    required String saveModsPath,
  }) async {
    try {
      await initialize();
      await _configService!.setPaths(modsPath, saveModsPath);
      return 'Config saved';
    } catch (e) {
      throw Exception('updateConfig error: $e');
    }
  }

  static Future<bool> renameMod(String oldId, String newName) async {
    try {
      await initialize();
      return await _modManager!.renameMod(oldId, newName);
    } catch (e) {
      throw Exception('renameMod error: $e');
    }
  }

  static Future<bool> deleteMod(String modId) async {
    try {
      await initialize();
      return await _modManager!.deleteMod(modId);
    } catch (e) {
      throw Exception('deleteMod error: $e');
    }
  }

  static Future<bool> updateMod(ModInfo mod) async {
    try {
      return true;
    } catch (e) {
      throw Exception('updateMod error: $e');
    }
  }

  static Future<ConfigService> getConfigService() async {
    await initialize();
    return _configService!;
  }

  static Future<ModManagerService> getModManagerService() async {
    await initialize();
    return _modManager!;
  }

  static Future<Map<String, String>> autoTagAllMods() async {
    try {
      await initialize();
      return await _modManager!.autoTagAllMods();
    } catch (e) {
      throw Exception('autoTagAllMods error: $e');
    }
  }

  static Future<bool> isFirstRun() async {
    await initialize();
    return _configService!.isFirstRun;
  }

  static Future<void> completeFirstRun() async {
    await initialize();
    await _configService!.setFirstRunComplete();
  }
}
