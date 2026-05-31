import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import '../core/constants.dart';
import '../models/character_info.dart';
import '../models/keybind_info.dart';
import '../services/api_service.dart';
import '../services/archive_service.dart';
import '../utils/state_providers.dart';
import '../utils/zzz_characters.dart';
import '../utils/path_helper.dart';
import '../l10n/app_localizations.dart';
import 'components/mode_toggle_widget.dart';
import 'components/character_cards_list_widget.dart';
import 'components/mod_card_widget.dart';
import 'components/keybinds_widget.dart';

class ModsScreen extends ConsumerStatefulWidget {
  const ModsScreen({super.key});

  @override
  ConsumerState<ModsScreen> createState() => _ModsScreenState();
}

class _ModsScreenState extends ConsumerState<ModsScreen>
    with TickerProviderStateMixin {
  AppLocalizations get loc => context.loc;
  bool isLoading = false;
  String? errorMessage;
  Map<String, String> modCharacterTags = {}; // modId -> characterId
  Set<String> favoriteMods = {};
  late AnimationController _loadingAnimationController;
  late Animation<double> _loadingAnimation;

  // Animation controller for mode toggle liquid effect
  late AnimationController _modeToggleAnimationController;
  late Animation<double> _modeToggleAnimation;

  // Debounce timers to prevent rapid rebuilds
  Timer? _rebuildDebounce;
  Timer? _characterSelectionDebounce;

  // Prevent multiple simultaneous operations
  bool _isOperationInProgress = false;
  bool _isLoadingMods = false;

  // Cache for preventing unnecessary rebuilds
  List<CharacterInfo>? _lastCharactersState;

  // Drag & drop state
  bool _isDragging = false;

  final FocusNode _focusNode = FocusNode();
  late final ScrollController _modsScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadingAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _loadingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _loadingAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    // Initialize liquid animation controller
    _modeToggleAnimationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _modeToggleAnimation = CurvedAnimation(
      parent: _modeToggleAnimationController,
      curve: Curves.easeInOutCubic,
    );

    _loadTags();
    loadMods();
  }

  @override
  void dispose() {
    _loadingAnimationController.dispose();
    _modeToggleAnimationController.dispose();
    _rebuildDebounce?.cancel();
    _characterSelectionDebounce?.cancel();
    _focusNode.dispose();
    _modsScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadTags() async {
    final configService = await ApiService.getConfigService();
    setState(() {
      modCharacterTags = configService.modCharacterTags;
    });
  }

  Future<void> _saveTag(String modId, String characterId) async {
    final configService = await ApiService.getConfigService();
    await configService.setModCharacterTag(modId, characterId);
    setState(() {
      modCharacterTags[modId] = characterId;
    });

    await loadMods(showLoading: false);
  }

  Future<void> loadMods({bool showLoading = true}) async {
    // Prevent multiple simultaneous load operations
    if (_isLoadingMods) return;
    _isLoadingMods = true;

    setState(() {
      if (showLoading) {
        isLoading = true;
      }
      errorMessage = null;
    });

    try {
      final loadedMods = await ApiService.getMods();
      final configService = await ApiService.getConfigService();
      final favoriteSet = configService.favoriteMods.toSet();
      final Map<String, List<ModInfo>> characterMods = {};
      final List<ModInfo> allMods = [];
      final List<String> validModIds = [];

      for (var oldMod in loadedMods) {
        validModIds.add(oldMod.id);

        String charId = modCharacterTags[oldMod.id] ?? 'unknown';

        if (charId == 'unknown') {
          for (var char in zzzCharacters) {
            if (oldMod.id.toLowerCase().contains(char.toLowerCase()) ||
                oldMod.name.toLowerCase().contains(char.toLowerCase())) {
              charId = char;
              break;
            }
          }
        }

        final localImagePath = path.join(
          PathHelper.getModImagesPath(),
          '${oldMod.id}.png',
        );
        final localImageFile = File(localImagePath);
        final imagePath = await localImageFile.exists()
            ? localImagePath
            : oldMod.imagePath;

        final mod = ModInfo(
          id: oldMod.id,
          name: oldMod.name,
          characterId: charId,
          isActive: oldMod.isActive,
          imagePath: imagePath,
          isFavorite: favoriteSet.contains(oldMod.id),
        );

        allMods.add(mod);

        if (!characterMods.containsKey(charId)) {
          characterMods[charId] = [];
        }
        characterMods[charId]!.add(mod);
      }

      await configService.cleanupInvalidTags(validModIds);

      setState(() {
        modCharacterTags = configService.modCharacterTags;
        favoriteMods = favoriteSet;
      });

      var characters = <CharacterInfo>[];

      final favoritesList = allMods.where((mod) => mod.isFavorite).toList();
      if (favoritesList.isNotEmpty) {
        characters.add(
          CharacterInfo(
            id: 'favorites',
            name: loc.t('mods.favorites'),
            iconPath: null,
            skins: favoritesList,
          ),
        );
      }

      if (allMods.isNotEmpty) {
        characters.add(
          CharacterInfo(
            id: 'all',
            name: loc.t('mods.all'),
            iconPath: null,
            skins: allMods,
          ),
        );
      }

      characters.addAll(
        zzzCharacters
            .map((charId) {
              return CharacterInfo(
                id: charId,
                name: getCharacterDisplayName(charId),
                iconPath: 'assets/characters/$charId.png',
                skins: characterMods[charId] ?? [],
              );
            })
            .where((char) => char.skins.isNotEmpty)
            .toList(),
      );

      try {
        final modManagerService = await ApiService.getModManagerService();
        characters = await modManagerService.enrichCharactersWithKeybinds(characters);
      } catch (e) {
        print('Failed to load keybinds: $e');
      }

      // Only update state if it actually changed to prevent unnecessary rebuilds
      final previousCharacters = ref.read(charactersProvider);
      final selectedIndex = ref.read(selectedCharacterIndexProvider);
      String? previousSelectedId;
      if (previousCharacters.isNotEmpty &&
          selectedIndex >= 0 &&
          selectedIndex < previousCharacters.length) {
        previousSelectedId = previousCharacters[selectedIndex].id;
      }

      if (_charactersActuallyChanged(characters)) {
        _lastCharactersState = List.from(characters);
        ref.read(charactersProvider.notifier).state = characters;
      }

      if (previousSelectedId != null && characters.isNotEmpty) {
        final newIndex = characters.indexWhere(
          (char) => char.id == previousSelectedId,
        );
        ref.read(selectedCharacterIndexProvider.notifier).state = newIndex != -1
            ? newIndex
            : 0;
      } else if (characters.isNotEmpty) {
        ref.read(selectedCharacterIndexProvider.notifier).state = 0;
      }

      if (showLoading) {
        setState(() => isLoading = false);
      } else if (mounted) {
        setState(() {});
      }
    } catch (e) {
      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    } finally {
      _isLoadingMods = false;
    }
  }

  Future<void> toggleMod(ModInfo mod) async {
    // Prevent multiple simultaneous operations
    if (_isOperationInProgress) return;
    _isOperationInProgress = true;

    // Cancel any pending debounce
    _rebuildDebounce?.cancel();

    try {
      final wasActive = mod.isActive;
      final activationMode = ref.read(activationModeProvider);

      // If activating a mod in single mode, deactivate other active mods for this character
      if (!wasActive && activationMode == ActivationMode.single) {
        await _deactivateOtherModsForCharacter(
          mod.characterId,
          excludeModId: mod.id,
        );
      }

      await ApiService.toggleMod(mod.id, currentlyActive: wasActive);

      if (mounted) {
        final characters = ref.read(charactersProvider);
        final updatedCharacters = characters.map((char) {
          final updatedSkins = char.skins.map((skin) {
            if (skin.id == mod.id) {
              return skin.copyWith(isActive: !wasActive);
            }
            if (!wasActive &&
                activationMode == ActivationMode.single &&
                skin.characterId == mod.characterId &&
                skin.id != mod.id &&
                skin.isActive) {
              return skin.copyWith(isActive: false);
            }
            return skin;
          }).toList();
          return char.copyWith(skins: updatedSkins);
        }).toList();

        ref.read(charactersProvider.notifier).state = updatedCharacters;
        _lastCharactersState = List.from(updatedCharacters);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              wasActive
                  ? loc.t('mods.snackbar.deactivated')
                  : loc.t('mods.snackbar.activated'),
            ),
            duration: AppConstants.snackBarDuration,
            behavior: SnackBarBehavior.floating,
            width: 200,
          ),
        );
      }
      _isOperationInProgress = false;
    } catch (e) {
      _isOperationInProgress = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _reloadMods() async {
    if (_isOperationInProgress) return;

    setState(() {
      _isOperationInProgress = true;
    });

    try {
      final modManagerService = await ref.read(
        modManagerServiceProvider.future,
      );
      final success = await modManagerService.reloadMods();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.error,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  success
                      ? loc.t('mods.snackbar.reload_success')
                      : loc.t('mods.snackbar.reload_failure'),
                ),
              ],
            ),
            backgroundColor: success ? Colors.green : Colors.red,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 300,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isOperationInProgress = false;
      });
    }
  }

  Future<void> _toggleFavorite(ModInfo mod) async {
    try {
      final configService = await ApiService.getConfigService();
      final isFavorite = favoriteMods.contains(mod.id);

      if (isFavorite) {
        await configService.removeFavoriteMod(mod.id);
      } else {
        await configService.addFavoriteMod(mod.id);
      }

      if (mounted) {
        setState(() {
          final updatedFavorites = Set<String>.from(favoriteMods);
          if (isFavorite) {
            updatedFavorites.remove(mod.id);
          } else {
            updatedFavorites.add(mod.id);
          }
          favoriteMods = updatedFavorites;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isFavorite
                  ? loc.t('mods.snackbar.favorites_removed')
                  : loc.t('mods.snackbar.favorites_added'),
            ),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            width: 240,
          ),
        );
      }

      await loadMods(showLoading: false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _refreshModsList() async {
    if (_isLoadingMods) return;
    await loadMods(showLoading: false);
    if (!mounted || errorMessage != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.t('mods.snackbar.list_refreshed')),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  Future<void> _toggleAllMods() async {
    final isDisabled = ref.read(allModsDisabledProvider);

    if (!isDisabled) {
      // Save which mods are currently active, then kill all of them
      final allCharacters = ref.read(charactersProvider);
      final allChar = allCharacters.firstWhere(
        (c) => c.id == 'all',
        orElse: () => CharacterInfo(id: 'all', name: '', iconPath: null, skins: []),
      );
      final activeIds = allChar.skins.where((m) => m.isActive).map((m) => m.id).toList();
      ref.read(savedActiveModsProvider.notifier).state = activeIds;

      setState(() => _isOperationInProgress = true);
      for (final id in activeIds) {
        await ApiService.toggleMod(id, currentlyActive: true);
      }
      setState(() => _isOperationInProgress = false);

      ref.read(allModsDisabledProvider.notifier).state = true;
      await loadMods(showLoading: false);
    } else {
      // Re-enable whatever was active before
      final savedIds = ref.read(savedActiveModsProvider);
      setState(() => _isOperationInProgress = true);
      for (final id in savedIds) {
        await ApiService.toggleMod(id, currentlyActive: false);
      }
      setState(() => _isOperationInProgress = false);

      ref.read(allModsDisabledProvider.notifier).state = false;
      ref.read(savedActiveModsProvider.notifier).state = [];
      await loadMods(showLoading: false);
    }
  }

  Widget _buildDisableAllToggle() {
    final isDisabled = ref.watch(allModsDisabledProvider);

    return Tooltip(
      message: isDisabled ? 'Re-enable all mods' : 'Disable all mods temporarily',
      child: GestureDetector(
        onTap: _isOperationInProgress ? null : _toggleAllMods,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isDisabled
                ? const Color(0xFFF59E0B)
                : const Color(0xFF64748B),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: (isDisabled
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF64748B))
                    .withOpacity(0.4),
                blurRadius: 12,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            isDisabled ? Icons.layers_clear : Icons.layers,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildAutoF10Toggle() {
    final autoF10Enabled = ref.watch(autoF10ReloadProvider);

    return Tooltip(
      message: autoF10Enabled
          ? loc.t('mods.tooltips.auto_f10_on')
          : loc.t('mods.tooltips.auto_f10_off'),
      child: GestureDetector(
        onTap: () {
          ref.read(autoF10ReloadProvider.notifier).state = !autoF10Enabled;
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: autoF10Enabled
                ? const Color(0xFF10B981)
                : const Color(0xFFEF4444),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color:
                    (autoF10Enabled
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444))
                        .withOpacity(0.4),
                blurRadius: 12,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            autoF10Enabled ? Icons.power : Icons.power_off,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildF10ReloadButton() {
    return Tooltip(
      message: loc.t('mods.tooltips.reload'),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0EA5E9).withOpacity(0.3),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _isOperationInProgress ? null : _reloadMods,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _isOperationInProgress ? 1 : 0,
                    duration: const Duration(milliseconds: 1000),
                    child: Icon(Icons.refresh, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'F10',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRefreshModsButton() {
    final isBusy = isLoading || _isLoadingMods;

    return Tooltip(
      message: loc.t('mods.tooltips.refresh'),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withOpacity(0.3),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isBusy ? null : _refreshModsList,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: isBusy
                        ? const SizedBox(
                            key: ValueKey('loader'),
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.sync,
                            key: ValueKey('icon'),
                            color: Colors.white,
                            size: 18,
                          ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    loc.t('mods.actions.refresh'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pasteImageFromClipboard(ModInfo mod) async {
    try {
      final imageBytes = await Pasteboard.image;
      if (imageBytes != null) {
        // Ensure the directory exists
        await PathHelper.ensureModImagesDirectoryExists();
        final appDir = Directory(PathHelper.getModImagesPath());

        final imagePath = path.join(appDir.path, '${mod.id}.png');
        final file = File(imagePath);

        if (await file.exists()) {
          await file.delete();
        }

        await file.writeAsBytes(imageBytes);

        if (mounted) {
          final imageProvider = FileImage(file);
          await imageProvider.evict();
          imageCache.clear();
          imageCache.clearLiveImages();
        }

        if (mounted) {
          final characters = ref.read(charactersProvider);
          final updatedCharacters = characters.map((char) {
            final updatedSkins = char.skins.map((skin) {
              if (skin.id == mod.id) {
                return skin.copyWith(imagePath: imagePath);
              }
              return skin;
            }).toList();
            return char.copyWith(skins: updatedSkins);
          }).toList();

          ref.read(charactersProvider.notifier).state = updatedCharacters;
          _lastCharactersState = List.from(updatedCharacters);

          setState(() {});

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('mods.snackbar.photo_updated')),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 1),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('mods.snackbar.clipboard_empty')),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showRenameDialog(ModInfo mod) async {
    final controller = TextEditingController(text: mod.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename mod'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName == null || newName.isEmpty || newName == mod.name) return;

    final success = await ApiService.renameMod(mod.id, newName);
    if (!mounted) return;

    if (success) {
      await loadMods(showLoading: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${mod.name}" renamed to "$newName"')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rename failed — name may already be taken')),
      );
    }
  }

  Future<void> _deleteMod(ModInfo mod) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete mod'),
        content: Text('Delete "${mod.name}"? This will permanently remove the mod folder from disk.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final success = await ApiService.deleteMod(mod.id);
    if (!mounted) return;

    if (success) {
      final characters = ref.read(charactersProvider);
      final updatedCharacters = characters.map((char) {
        return char.copyWith(
          skins: char.skins.where((s) => s.id != mod.id).toList(),
        );
      }).toList();
      ref.read(charactersProvider.notifier).state = updatedCharacters;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${mod.name}" deleted')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete "${mod.name}"')),
      );
    }
  }

  void _showEditDialog(ModInfo mod) {
    final selectedChar = ValueNotifier<String>(mod.characterId);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('mods.dialog.edit_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mod.name,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            Text(
              loc.t('mods.dialog.character_tag'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: selectedChar,
              builder: (context, value, _) {
                return DropdownButtonFormField<String>(
                  value: zzzCharacters.contains(value)
                      ? value
                      : zzzCharacters.first,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                  items: zzzCharacters.map((charId) {
                    return DropdownMenuItem(
                      value: charId,
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.asset(
                              'assets/characters/$charId.png',
                              width: 24,
                              height: 24,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.person,
                                size: 24,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(getCharacterDisplayName(charId)),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (newValue) {
                    if (newValue != null) {
                      selectedChar.value = newValue;
                    }
                  },
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('mods.dialog.cancel')),
          ),
          FilledButton(
            onPressed: () async {
              await _saveTag(mod.id, selectedChar.value);
              await loadMods(showLoading: false);
              Navigator.pop(context);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(loc.t('mods.snackbar.tag_saved')),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            },
            child: Text(loc.t('mods.dialog.save')),
          ),
        ],
      ),
    );
  }

  void _showEditKeybindDialog(ModInfo mod, KeybindInfo keybind) {
    final keyController = TextEditingController(text: keybind.keyValue ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Edit Keybind: ${keybind.displayName}',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Press the key combination you want to use:',
              style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: keyController,
              decoration: InputDecoration(
                labelText: 'Key Combination',
                hintText: 'e.g., VK_F1, CTRL VK_A',
                prefixIcon: const Icon(Icons.keyboard, color: Color(0xFFFBBF24)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFFBBF24), width: 2),
                ),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withOpacity(0.5),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Common keys:',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFE2E8F0),
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'VK_F1 to VK_F12, VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT\nCTRL, ALT, SHIFT, no_alt, no_shift, no_CTRL',
                    style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newKey = keyController.text.trim();
              if (newKey.isNotEmpty) {
                await _saveKeybindChange(mod, keybind, newKey);
                Navigator.pop(context);
                await loadMods(showLoading: false);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveKeybindChange(ModInfo mod, KeybindInfo keybind, String newKey) async {
    try {
      final modManagerService = await ApiService.getModManagerService();
      final modsPath = modManagerService.modsPath;
      
      if (modsPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Mods path not configured')),
          );
        }
        return;
      }

      final modPath = path.join(modsPath, mod.id);
      final modDir = Directory(modPath);
      
      if (!await modDir.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Mod directory not found')),
          );
        }
        return;
      }

      final iniFiles = await modDir
          .list(recursive: true)
          .where((entity) => entity is File && entity.path.toLowerCase().endsWith('.ini'))
          .cast<File>()
          .toList();

      if (iniFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No INI file found')),
          );
        }
        return;
      }

      for (final iniFile in iniFiles) {
        String content = await iniFile.readAsString();
        final lines = content.split('\n');
        bool inTargetSection = false;
        bool updated = false;

        for (int i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          
          if (line.toLowerCase() == '[${keybind.section.toLowerCase()}]') {
            inTargetSection = true;
            continue;
          }
          if (line.startsWith('[') && line.endsWith(']')) {
            inTargetSection = false;
          }
          if (inTargetSection && line.toLowerCase().startsWith('key =')) {
            lines[i] = 'key = $newKey';
            updated = true;
            break;
          }
        }

        if (updated) {
          await iniFile.writeAsString(lines.join('\n'));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Keybind updated: ${keybind.displayName} → $newKey'),
                backgroundColor: const Color(0xFF10B981),
              ),
            );
          }
          break;
        }
      }
    } catch (e) {
      print('Error saving keybind: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving keybind: $e')),
        );
      }
    }
  }

  void _showKeybindsDialog(ModInfo mod) {
    if (mod.keybinds == null || mod.keybinds!.isEmpty) return;

    final validKeybinds = mod.keybinds!
        .where((kb) => kb.keyValue != null && kb.keyValue!.isNotEmpty)
        .toList();

    if (validKeybinds.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.keyboard_outlined, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Keybinds: ${mod.name}',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: validKeybinds.map((keybind) {
                return InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    _showEditKeybindDialog(mod, keybind);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF1E293B).withOpacity(0.8),
                          const Color(0xFF0F172A).withOpacity(0.9),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF334155),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          keybind.displayName,
                          style: const TextStyle(
                            color: Color(0xFFE2E8F0),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xFFFBBF24).withOpacity(0.3),
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            keybind.keyValue ?? '',
                            style: const TextStyle(
                              color: Color(0xFFFBBF24),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: Color(0xFF94A3B8),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context, ModInfo mod, Offset position) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.edit, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.edit')),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _showEditDialog(mod));
          },
        ),
        PopupMenuItem(
          child: const Row(
            children: [
              Icon(Icons.drive_file_rename_outline, size: 18),
              SizedBox(width: 8),
              Text('Rename'),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _showRenameDialog(mod));
          },
        ),
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.image, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.add_image')),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _pasteImageFromClipboard(mod));
          },
        ),
        if (mod.keybinds != null && mod.keybinds!.isNotEmpty)
          PopupMenuItem(
            child: Row(
              children: [
                const Icon(Icons.keyboard_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Keybinds (${mod.keybinds!.length})'),
              ],
            ),
            onTap: () {
              Future.delayed(Duration.zero, () => _showKeybindsDialog(mod));
            },
          ),
        PopupMenuItem(
          child: Row(
            children: [
              Icon(mod.isFavorite ? Icons.star : Icons.star_border, size: 18),
              const SizedBox(width: 8),
              Text(
                mod.isFavorite
                    ? loc.t('mods.context_menu.favorite_remove')
                    : loc.t('mods.context_menu.favorite_add'),
              ),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _toggleFavorite(mod));
          },
        ),
        PopupMenuItem(
          child: Row(
            children: [
              Icon(mod.isActive ? Icons.toggle_off : Icons.toggle_on, size: 18),
              const SizedBox(width: 8),
              Text(
                mod.isActive
                    ? loc.t('mods.context_menu.deactivate')
                    : loc.t('mods.context_menu.activate'),
              ),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => toggleMod(mod));
          },
        ),
        PopupMenuItem(
          child: const Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Delete', style: TextStyle(color: Colors.red)),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _deleteMod(mod));
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final characters = ref.watch(charactersProvider);
    final selectedIndex = ref.watch(selectedCharacterIndexProvider);
    final currentSkins = ref.watch(currentCharacterSkinsProvider);
    final isDarkMode = ref.watch(isDarkModeProvider);

    if (isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _loadingAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: 0.8 + (_loadingAnimation.value * 0.2),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0EA5E9).withOpacity(0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            AnimatedBuilder(
              animation: _loadingAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: _loadingAnimation.value,
                  child: Text(
                    loc.t('mods.loading.title'),
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      );
    }

    if (errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              loc.t('mods.errors.load'),
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              errorMessage!,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () => loadMods(),
              icon: const Icon(Icons.refresh),
              label: Text(loc.t('mods.errors.retry')),
            ),
          ],
        ),
      );
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final isControlPressed =
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed;
          if (isControlPressed && event.logicalKey == LogicalKeyboardKey.keyV) {
            _handlePasteFromClipboard();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          Container(
            height: 140,
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(
                bottom: BorderSide(
                  color: isDarkMode
                      ? Colors.white.withOpacity(0.1)
                      : Colors.black.withOpacity(0.05),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.all(AppConstants.defaultPadding),
                  child: Row(
                    children: [
                      Text(
                        loc.t('mods.headers.characters'),
                        style: TextStyle(
                          fontSize: AppConstants.headerTextSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: AppConstants.smallPadding,
                          vertical: AppConstants.tinyPadding,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            AppConstants.activeModBorderColor,
                          ).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(
                            AppConstants.smallPadding,
                          ),
                        ),
                        child: Text(
                          '${characters.length}',
                          style: TextStyle(
                            fontSize: AppConstants.captionTextSize,
                            color: const Color(
                              AppConstants.activeModBorderColor,
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Disable all mods toggle
                      _buildDisableAllToggle(),
                      const SizedBox(width: 12),
                      // Auto F10 toggle
                      _buildAutoF10Toggle(),
                      const SizedBox(width: 12),
                      _buildRefreshModsButton(),
                      const SizedBox(width: 12),
                      // F10 Reload button
                      _buildF10ReloadButton(),
                      const SizedBox(width: 12),
                      // Mode toggle buttons
                      ModeToggleWidget(
                        modeToggleAnimationController:
                            _modeToggleAnimationController,
                        modeToggleAnimation: _modeToggleAnimation,
                        activationMode: ref.watch(activationModeProvider),
                        onModeChanged: (ActivationMode newMode) {
                          _rebuildDebounce?.cancel();
                          _characterSelectionDebounce?.cancel();
                          _isOperationInProgress = false;
                          ref.read(activationModeProvider.notifier).state =
                              newMode;
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CharacterCardsListWidget(
                    characters: characters,
                    selectedIndex: selectedIndex,
                    onCharacterSelected: (int index) {
                      ref.read(selectedCharacterIndexProvider.notifier).state =
                          index;
                    },
                    onCharacterTagSaved: _saveTag,
                    modCharacterTags: modCharacterTags,
                  ),
                ),
              ],
            ),
          ),
          // Counter for active mods
          if (currentSkins.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: AppConstants.defaultPadding,
                vertical: AppConstants.smallPadding,
              ),
              child: Row(
                children: [
                  Text(
                    loc.t('mods.headers.active_mods'),
                    style: TextStyle(
                      fontSize: AppConstants.titleTextSize,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(width: AppConstants.smallMargin),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppConstants.smallPadding,
                      vertical: AppConstants.tinyPadding,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(
                        AppConstants.activeModCountColor,
                      ).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(
                        AppConstants.smallPadding,
                      ),
                    ),
                    child: Text(
                      '${currentSkins.where((mod) => mod.isActive).length}/${currentSkins.length}',
                      style: TextStyle(
                        fontSize: AppConstants.captionTextSize,
                        color: const Color(AppConstants.activeModCountColor),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> animation) {
                final isOldWidget =
                    child.key !=
                        ValueKey(
                          'character_${selectedIndex}_${currentSkins.length}',
                        ) &&
                    child.key != const ValueKey('empty');

                final outOffset =
                    Tween<Offset>(
                      begin: Offset.zero,
                      end: const Offset(-1.0, 0),
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeInCubic,
                      ),
                    );

                final inOffset =
                    Tween<Offset>(
                      begin: const Offset(1.0, 0),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    );

                final scaleAnimation = Tween<double>(begin: 0.8, end: 1.0)
                    .animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    );

                return SlideTransition(
                  position: animation.status == AnimationStatus.reverse
                      ? outOffset
                      : inOffset,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: scaleAnimation, child: child),
                  ),
                );
              },
              child: Padding(
                key: ValueKey(
                  'character_${selectedIndex}_${currentSkins.length}',
                ),
                padding: EdgeInsets.all(AppConstants.defaultPadding),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return DropTarget(
                      onDragEntered: (details) {
                        setState(() => _isDragging = true);
                      },
                      onDragExited: (details) {
                        setState(() => _isDragging = false);
                      },
                      onDragDone: (details) {
                        _importModsFromFolders(details.files);
                      },
                      child: currentSkins.isEmpty && characters.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.inbox_outlined,
                                    size: 64,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    loc.t('mods.empty.title'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  SizedBox(
                                    width: 250,
                                    height: 350,
                                    child: _buildAddModCard(),
                                  ),
                                ],
                              ),
                            )
                          : AnimationLimiter(
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(context)
                                    .copyWith(
                                      dragDevices: {
                                        PointerDeviceKind.touch,
                                        PointerDeviceKind.mouse,
                                        PointerDeviceKind.trackpad,
                                        PointerDeviceKind.stylus,
                                      },
                                      physics: const BouncingScrollPhysics(),
                                    ),
                                child: GridView.builder(
                                  controller: _modsScrollController,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: AppConstants.smallPadding,
                                  ),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 6,
                                        childAspectRatio: 0.7,
                                        crossAxisSpacing: 16,
                                        mainAxisSpacing: 16,
                                      ),
                                  itemCount: currentSkins.length + 1,
                                  itemBuilder: (context, index) {
                                    if (index == currentSkins.length) {
                                      return AnimationConfiguration.staggeredGrid(
                                        key: const ValueKey('add_mod_card'),
                                        position: index,
                                        columnCount: 4,
                                        duration: const Duration(
                                          milliseconds: 500,
                                        ),
                                        child: ScaleAnimation(
                                          scale: 0.5,
                                          curve: Curves.easeOutBack,
                                          child: FadeInAnimation(
                                            curve: Curves.easeOut,
                                            child: _buildAddModCard(),
                                          ),
                                        ),
                                      );
                                    }

                                    final mod = currentSkins[index];
                                    return AnimationConfiguration.staggeredGrid(
                                      key: ValueKey(
                                        'mod_${mod.id}_${mod.isActive}',
                                      ),
                                      position: index,
                                      columnCount: 4,
                                      duration: const Duration(
                                        milliseconds: 500,
                                      ),
                                      child: ScaleAnimation(
                                        scale: 0.5,
                                        curve: Curves.easeOutBack,
                                        child: FadeInAnimation(
                                          curve: Curves.easeOut,
                                          child: _buildModCard(mod),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddModCard() {
    final isDarkMode = ref.watch(isDarkModeProvider);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _showImportDialog,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _isDragging
                  ? [
                      const Color(0xFF0EA5E9).withOpacity(0.3),
                      const Color(0xFF06B6D4).withOpacity(0.3),
                    ]
                  : [
                      isDarkMode
                          ? const Color(0xFF1F2937).withOpacity(0.5)
                          : const Color(0xFFF9FAFB),
                      isDarkMode
                          ? const Color(0xFF111827).withOpacity(0.5)
                          : const Color(0xFFF3F4F6),
                    ],
            ),
            border: Border.all(
              color: _isDragging
                  ? const Color(0xFF0EA5E9)
                  : isDarkMode
                  ? Colors.white.withOpacity(0.1)
                  : Colors.black.withOpacity(0.08),
              width: _isDragging ? 2.5 : 2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
            boxShadow: _isDragging
                ? [
                    BoxShadow(
                      color: const Color(0xFF0EA5E9).withOpacity(0.3),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: isDarkMode
                          ? Colors.black.withOpacity(0.2)
                          : Colors.grey.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(19)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _isDragging
                        ? const Color(0xFF0EA5E9).withOpacity(0.2)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.05)
                              : Colors.black.withOpacity(0.03)),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isDragging ? Icons.file_download : Icons.add,
                    size: 48,
                    color: _isDragging
                        ? const Color(0xFF0EA5E9)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.6)
                              : Colors.black.withOpacity(0.4)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isDragging
                      ? loc.t('mods.empty.prompt')
                      : loc.t('mods.empty.cta'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _isDragging
                        ? const Color(0xFF0EA5E9)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.7)
                              : Colors.black.withOpacity(0.6)),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _isDragging
                        ? loc.t('mods.empty.add_folders')
                        : loc.t('mods.empty.drag'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDarkMode
                          ? Colors.white.withOpacity(0.5)
                          : Colors.black.withOpacity(0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModCard(ModInfo mod) {
    final isDarkMode = ref.watch(isDarkModeProvider);

    return LongPressDraggable<ModInfo>(
      data: mod,
      delay: AppConstants.dragDelay,
      hapticFeedbackOnStart: true,
      feedback: Material(
        elevation: AppConstants.dragFeedbackElevation,
        borderRadius: BorderRadius.circular(AppConstants.modCardBorderRadius),
        child: Container(
          width: 200, // Fixed width for feedback
          height: 280, // Fixed height for feedback
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(
              AppConstants.modCardBorderRadius,
            ),
            border: Border.all(
              color: const Color(AppConstants.activeModBorderColor),
              width: AppConstants.modCardBorderWidthActive,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  AppConstants.activeModBorderColor,
                ).withOpacity(0.3),
                blurRadius: AppConstants.modCardBlurRadiusActive,
                spreadRadius: AppConstants.modCardSpreadRadiusActive,
              ),
            ],
          ),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  child:
                      mod.imagePath != null && File(mod.imagePath!).existsSync()
                      ? Image.file(
                          File(mod.imagePath!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                        )
                      : Container(
                          color: Colors.grey.withOpacity(0.1),
                          child: Icon(
                            Icons.image_not_supported,
                            size: 32,
                            color: Colors.grey[600],
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  mod.name,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: AppConstants.dragFeedbackOpacity,
        child: ModCardWidget(
          mod: mod,
          isDarkMode: isDarkMode,
          modCharacterTags: modCharacterTags,
          getCharacterName: _getCharacterName,
          onFavoriteToggle: () {},
        ),
      ),
      child: Tooltip(
        message: loc.t('mods.tooltips.card'),
        child: GestureDetector(
          onTap: () => toggleMod(mod),
          onSecondaryTapDown: (details) {
            _showContextMenu(context, mod, details.globalPosition);
          },
          child: ModCardWidget(
            mod: mod,
            isDarkMode: isDarkMode,
            modCharacterTags: modCharacterTags,
            getCharacterName: _getCharacterName,
            onFavoriteToggle: () => _toggleFavorite(mod),
          ),
        ),
      ),
    );
  }

  String _getCharacterName(String characterId) {
    try {
      final characters = ref.read(charactersProvider);
      final character = characters.firstWhere((char) => char.id == characterId);
      return character.name;
    } catch (e) {
      return loc.t('common.unknown');
    }
  }

  bool _charactersActuallyChanged(List<CharacterInfo> newCharacters) {
    if (_lastCharactersState == null) return true;
    if (_lastCharactersState!.length != newCharacters.length) return true;

    for (int i = 0; i < newCharacters.length; i++) {
      final oldChar = _lastCharactersState![i];
      final newChar = newCharacters[i];

      if (oldChar.id != newChar.id ||
          oldChar.name != newChar.name ||
          oldChar.skins.length != newChar.skins.length) {
        return true;
      }

      // Check if any mod states changed
      for (int j = 0; j < newChar.skins.length; j++) {
        if (oldChar.skins[j].id != newChar.skins[j].id ||
            oldChar.skins[j].isActive != newChar.skins[j].isActive ||
            oldChar.skins[j].name != newChar.skins[j].name ||
            oldChar.skins[j].isFavorite != newChar.skins[j].isFavorite) {
          return true;
        }
      }
    }

    return false;
  }

  Future<void> _deactivateOtherModsForCharacter(
    String characterId, {
    String? excludeModId,
  }) async {
    try {
      final characters = ref.read(charactersProvider);
      final character = characters.firstWhere(
        (char) => char.id == characterId,
        orElse: () =>
            CharacterInfo(id: '', name: '', iconPath: null, skins: []),
      );

      if (character.id.isNotEmpty) {
        final activeMods = character.skins
            .where((mod) => mod.isActive && mod.id != excludeModId)
            .toList();
        for (final mod in activeMods) {
          await ApiService.toggleMod(mod.id, currentlyActive: true);
        }
      }
    } catch (e) {
      // Handle error silently
    }
  }

  Future<void> _importModsFromFolders(List<XFile> files) async {
    if (_isOperationInProgress) return;

    setState(() {
      _isOperationInProgress = true;
      _isDragging = false;
    });

    bool dialogShown = false;

    try {
      final folderPaths = <String>[];
      final archivesToExtract = <XFile>[];
      final successfullyExtractedArchives = <String>[];
      final tempFoldersToCleanup = <String>[];

      for (final file in files) {
        if (ArchiveService.isArchiveFile(file.path)) {
          archivesToExtract.add(file);
          print('ModsScreen: found archive: ${file.path}');
        } else {
          final dir = Directory(file.path);
          if (await dir.exists()) {
            folderPaths.add(file.path);
          }
        }
      }

      if (archivesToExtract.isNotEmpty) {
        print('ModsScreen: extracting ${archivesToExtract.length} archives...');

        for (final archiveFile in archivesToExtract) {
          final file = File(archiveFile.path);
          if (!await file.exists()) {
            print('ModsScreen: file not found: ${archiveFile.path}');
            continue;
          }

          final result = await ArchiveService.extractArchive(archiveFile: file);

          if (result.success && result.extractedFolders != null) {
            folderPaths.addAll(result.extractedFolders!);
            tempFoldersToCleanup.addAll(result.extractedFolders!);
            successfullyExtractedArchives.add(archiveFile.path);
            print('ModsScreen: extracted ${result.extractedFolders!.length} folders from ${archiveFile.name}');
          } else {
            print('ModsScreen: extract failed for ${archiveFile.name}: ${result.error}');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Extract failed for ${archiveFile.name}: ${result.error}'),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        }
      }

      if (folderPaths.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('mods.snackbar.import_no_folders')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (mounted) {
        dialogShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => PopScope(
            canPop: false,
            child: AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 50,
                    height: 50,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF0EA5E9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    loc.t(
                      'mods.dialog.import_progress',
                      params: {
                        'count': folderPaths.length.toString(),
                        'plural': folderPaths.length == 1
                            ? loc.t('mods.import.single')
                            : loc.t('mods.import.plural'),
                      },
                    ),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    loc.t('mods.dialog.import_progress_hint'),
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      final modManagerService = await ref.read(
        modManagerServiceProvider.future,
      );
      final (importedMods, autoTags) = await modManagerService.importMods(
        folderPaths,
      );

      if (mounted && dialogShown) {
        Navigator.of(context).pop();
        dialogShown = false;
      }

      if (importedMods.isEmpty) {
        if (tempFoldersToCleanup.isNotEmpty) {
          print('ModsScreen: cleaning up ${tempFoldersToCleanup.length} temp folders (import failed)...');
          for (final tempPath in tempFoldersToCleanup) {
            try {
              final tempDir = Directory(tempPath);
              if (await tempDir.exists()) {
                final parentDir = tempDir.parent;
                if (parentDir.path.contains('zzz_archive_extract_')) {
                  await parentDir.delete(recursive: true);
                  print('ModsScreen: removed temp dir: ${parentDir.path}');
                }
              }
            } catch (e) {
              print('ModsScreen: cleanup error for $tempPath: $e');
            }
          }
        }
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(loc.t('mods.snackbar.import_duplicates')),
                  ),
                ],
              ),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final configService = await ApiService.getConfigService();
      for (final entry in autoTags.entries) {
        await configService.setModCharacterTag(entry.key, entry.value);
      }

      setState(() {
        modCharacterTags.addAll(autoTags);
      });

      await loadMods(showLoading: false);

      if (successfullyExtractedArchives.isNotEmpty) {
        print('ModsScreen: deleting ${successfullyExtractedArchives.length} archives...');
        for (final archivePath in successfullyExtractedArchives) {
          try {
            final archiveFile = File(archivePath);
            if (await archiveFile.exists()) {
              await archiveFile.delete();
              print('ModsScreen: deleted archive: $archivePath');
            }
          } catch (e) {
            print('ModsScreen: failed to delete archive $archivePath: $e');
          }
        }
      }

      if (tempFoldersToCleanup.isNotEmpty) {
        print('ModsScreen: cleaning up ${tempFoldersToCleanup.length} temp folders...');
        for (final tempPath in tempFoldersToCleanup) {
          try {
            final tempDir = Directory(tempPath);
            if (await tempDir.exists()) {
              final parentDir = tempDir.parent;
              if (parentDir.path.contains('zzz_archive_extract_')) {
                await parentDir.delete(recursive: true);
                print('ModsScreen: removed temp dir: ${parentDir.path}');
              }
            }
          } catch (e) {
            print('ModsScreen: cleanup error for $tempPath: $e');
          }
        }
      }

      if (mounted) {
        final hasAutoTags = autoTags.isNotEmpty;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF10B981),
                  size: 28,
                ),
                const SizedBox(width: 8),
                Text(loc.t('mods.snackbar.import_success_title')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.t(
                    importedMods.length == 1
                        ? 'mods.import.success_single'
                        : 'mods.import.success_plural',
                    params: {'count': importedMods.length.toString()},
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hasAutoTags) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF0EA5E9).withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome,
                              color: Color(0xFF0EA5E9),
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              loc.t('mods.dialog.import_auto_tags'),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF0EA5E9),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...autoTags.entries
                            .take(5)
                            .map(
                              (entry) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Text(
                                  '• ${entry.key} → ${getCharacterDisplayName(entry.value)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                        if (autoTags.length > 5)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              loc.t(
                                'mods.import.auto_tag_and_more',
                                params: {
                                  'count': (autoTags.length - 5).toString(),
                                },
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  loc.t('mods.dialog.import_ready'),
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(loc.t('mods.dialog.great')),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted && dialogShown) {
        Navigator.of(context).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Import failed: $e')),
              ],
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isOperationInProgress = false;
        });
      }
    }
  }

  Future<void> _showImportDialog() async {
    if (_isOperationInProgress) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.add_circle_outline, color: Color(0xFF0EA5E9)),
            SizedBox(width: 8),
            Text('Add mods'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Drag mod folders into the app window, press Ctrl+V to paste from clipboard, or copy them directly into the mods folder.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF0EA5E9).withOpacity(0.3),
                ),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline,
                    color: Color(0xFF0EA5E9),
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'If the folder name contains a character name, the tag gets set automatically!',
                      style: TextStyle(fontSize: 12, color: Color(0xFF0EA5E9)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _handlePasteFromClipboard() async {
    if (_isOperationInProgress) return;

    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData == null ||
          clipboardData.text == null ||
          clipboardData.text!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('clipboard.empty')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final paths = clipboardData.text!
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      if (paths.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('clipboard.no_paths')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final validFolders = <XFile>[];
      for (final filePath in paths) {
        String cleanPath = filePath;
        if (cleanPath.startsWith('file://')) {
          cleanPath = Uri.parse(cleanPath).toFilePath();
        }

        final dir = Directory(cleanPath);
        if (await dir.exists()) {
          validFolders.add(XFile(cleanPath));
        }
      }

      if (validFolders.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('clipboard.no_valid')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      await _importModsFromFolders(validFolders);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t(
                'mods.snackbar.paste_error',
                params: {'message': e.toString()},
              ),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

class _ModCardWidget extends StatefulWidget {
  final ModInfo mod;
  final bool isDarkMode;
  final Map<String, String> modCharacterTags;
  final String Function(String) getCharacterName;
  final LinearGradient Function(ModInfo, bool, bool) getModCardGradient;
  final Color Function(ModInfo, bool, bool) getModCardBorderColor;
  final List<BoxShadow> Function(ModInfo, bool, bool) getModCardShadows;

  const _ModCardWidget({
    required this.mod,
    required this.isDarkMode,
    required this.modCharacterTags,
    required this.getCharacterName,
    required this.getModCardGradient,
    required this.getModCardBorderColor,
    required this.getModCardShadows,
  });

  @override
  State<_ModCardWidget> createState() => _ModCardWidgetState();
}

class _ModCardWidgetState extends State<_ModCardWidget> {
  bool isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        transform: Matrix4.identity()
          ..scale(isHovered ? 1.02 : 1.0)
          ..translate(0.0, isHovered ? -4.0 : 0.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: widget.getModCardGradient(
            widget.mod,
            widget.isDarkMode,
            isHovered,
          ),
          border: Border.all(
            color: widget.getModCardBorderColor(
              widget.mod,
              widget.isDarkMode,
              isHovered,
            ),
            width: widget.mod.isActive ? 2.5 : (isHovered ? 2.0 : 1.2),
          ),
          boxShadow: widget.getModCardShadows(
            widget.mod,
            widget.isDarkMode,
            isHovered,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            gradient: isHovered
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.fromRGBO(255, 255, 255, 0.05),
                      Colors.transparent,
                    ],
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient:
                          widget.mod.imagePath != null &&
                              File(widget.mod.imagePath!).existsSync()
                          ? null
                          : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                widget.isDarkMode
                                    ? const Color(0xFF374151)
                                    : const Color(0xFFF3F4F6),
                                widget.isDarkMode
                                    ? const Color(0xFF1F2937)
                                    : const Color(0xFFE5E7EB),
                              ],
                            ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.mod.imagePath != null &&
                            File(widget.mod.imagePath!).existsSync())
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            child: Image.file(
                              File(widget.mod.imagePath!),
                              fit: BoxFit.cover,
                              key: ValueKey(
                                '${widget.mod.id}_${widget.mod.imagePath}',
                              ),
                              cacheWidth: null,
                              cacheHeight: null,
                            ),
                          )
                        else
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: widget.isDarkMode
                                    ? Color.fromRGBO(255, 255, 255, 0.05)
                                    : Color.fromRGBO(0, 0, 0, 0.03),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.image_outlined,
                                size: 40,
                                color: widget.isDarkMode
                                    ? Color.fromRGBO(255, 255, 255, 0.4)
                                    : Color.fromRGBO(0, 0, 0, 0.4),
                              ),
                            ),
                          ),

                        if (widget.mod.imagePath != null &&
                            File(widget.mod.imagePath!).existsSync())
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Color.fromRGBO(0, 0, 0, 0.1),
                                ],
                              ),
                            ),
                          ),

                        Positioned(
                          top: 12,
                          right: 12,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: widget.mod.isActive
                                  ? const Color(0xFF10B981)
                                  : widget.isDarkMode
                                  ? const Color(0xFF374151)
                                  : const Color(0xFF6B7280),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.mod.isActive
                                      ? Color.fromRGBO(16, 185, 129, 0.3)
                                      : Color.fromRGBO(0, 0, 0, 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Icon(
                              widget.mod.isActive
                                  ? Icons.check_rounded
                                  : Icons.close_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),

                        if (widget.modCharacterTags.containsKey(widget.mod.id))
                          Positioned(
                            top: 12,
                            left: 12,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0EA5E9),
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: [
                                  BoxShadow(
                                    color: Color.fromRGBO(14, 165, 233, 0.4),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                widget.getCharacterName(
                                  widget.modCharacterTags[widget.mod.id]!,
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(18),
                  ),
                  color: widget.mod.isActive
                      ? (widget.isDarkMode
                            ? Color.fromRGBO(14, 165, 233, 0.1)
                            : Color.fromRGBO(14, 165, 233, 0.05))
                      : (widget.isDarkMode
                            ? Color.fromRGBO(255, 255, 255, 0.02)
                            : Color.fromRGBO(0, 0, 0, 0.01)),
                ),
                child: Text(
                  widget.mod.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: widget.mod.isActive
                        ? const Color(0xFF0EA5E9)
                        : (widget.isDarkMode
                              ? Color.fromRGBO(255, 255, 255, 0.9)
                              : Color.fromRGBO(0, 0, 0, 0.8)),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
