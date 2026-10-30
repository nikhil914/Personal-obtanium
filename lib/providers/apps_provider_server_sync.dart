import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/root_installer.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/server_sync_service.dart';

class ServerSyncResult {
  final bool fromServer;
  final int listed;
  final List<String> addedIds;
  final List<String> queuedIds;
  final List<String> installedIds;
  final bool usingRoot;
  final MultiAppMultiError errors;

  const ServerSyncResult({
    required this.fromServer,
    required this.listed,
    required this.addedIds,
    required this.queuedIds,
    required this.installedIds,
    required this.usingRoot,
    required this.errors,
  });

  bool get hasErrors => errors.idsByErrorString.isNotEmpty;
}

String? findAppIdForServerUrl(
  Iterable<App> apps,
  String rawUrl,
  String? standardUrl,
) {
  String norm(String u) =>
      u.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
  final candidates = {norm(rawUrl), if (standardUrl != null) norm(standardUrl)};
  for (final app in apps) {
    if (candidates.contains(norm(app.url))) return app.id;
  }
  return null;
}

extension AppsProviderServerSync on AppsProvider {
  Future<bool> applyRootPreference() async {
    final mode = settingsProvider.installerMode;
    final rootInstaller = RootInstaller(settingsProvider);
    if (mode == InstallerMode.root.name) {
      if (await rootInstaller.checkPermission()) return true;
      if (settingsProvider.preferRootWhenAvailable) {
        AppLogger.info(
          'Server sync: root is no longer available, using the system installer.',
        );
        settingsProvider.installerMode = InstallerMode.system.name;
      }
      return false;
    }
    if (mode != InstallerMode.system.name ||
        !settingsProvider.preferRootWhenAvailable) {
      return false;
    }
    if (await rootInstaller.checkPermission()) {
      AppLogger.info('Server sync: root granted, installs will be silent.');
      settingsProvider.installerMode = InstallerMode.root.name;
      return true;
    }
    return false;
  }

  Future<ServerSyncResult> syncFromServer({
    BuildContext? context,
    List<ServerAppEntry>? entries,
  }) async {
    final url = settingsProvider.serverSyncUrl;
    final fromServer = entries != null || url.isNotEmpty;
    entries ??= url.isEmpty ? const [] : await fetchServerAppList(url);
    AppLogger.info('Server sync: ${entries.length} apps listed by the server.');
    await waitForAppsToLoad();
    final usingRoot = await applyRootPreference();
    final errors = MultiAppMultiError();
    final sourceProvider = SourceProvider();
    final existingIds = apps.values
        .where((e) => !e.app.disabled)
        .map((e) => e.app.id)
        .toSet();
    final managedIds = {...existingIds};
    final toFetch = <ServerAppEntry, AppSource>{};

    for (final entry in entries) {
      try {
        final source = sourceProvider.getSource(entry.url);
        String? standardUrl;
        try {
          standardUrl = source.standardizeUrl(entry.url);
        } catch (_) {}
        final existingId = findAppIdForServerUrl(
          apps.values.map((e) => e.app),
          entry.url,
          standardUrl,
        );
        if (existingId != null) {
          managedIds.add(existingId);
          existingIds.add(existingId);
        } else {
          toFetch[entry] = source;
        }
      } catch (e) {
        errors.add(entry.url, e, appName: entry.url);
      }
    }

    final addedIds = <String>[];
    final pending = toFetch.entries.toList();
    for (var i = 0; i < pending.length; i += kDefaultFetchConcurrency) {
      final batch = pending.skip(i).take(kDefaultFetchConcurrency).toList();
      final results = await Future.wait(
        batch.map((e) async {
          try {
            final settings = {
              ...getDefaultValuesFromFormItems(
                e.value.combinedAppSpecificSettingFormItems,
              ),
              ...serverSyncDefaultAppSettings,
              ...e.key.settings,
            };
            return await sourceProvider.getApp(e.value, e.key.url, settings);
          } catch (err) {
            return err;
          }
        }),
      );
      for (var j = 0; j < batch.length; j++) {
        final result = results[j];
        final entryUrl = batch[j].key.url;
        if (result is App) {
          if (apps.containsKey(result.id)) {
            managedIds.add(result.id);
            existingIds.add(result.id);
            continue;
          }
          await saveApps([result], onlyIfExists: false);
          addedIds.add(result.id);
          managedIds.add(result.id);
        } else {
          errors.add(entryUrl, result, appName: entryUrl);
        }
      }
    }
    AppLogger.info('Server sync: added ${addedIds.length} new apps.');

    if (existingIds.isNotEmpty) {
      try {
        await checkUpdates(specificIds: existingIds.toList());
      } on CheckUpdatesException catch (e) {
        e.errors.rawErrors.forEach(
          (id, err) => errors.add(id, err, appName: apps[id]?.name),
        );
      }
    }

    final queuedIds = findAppIdsWithPendingUpdates()
        .where(managedIds.contains)
        .where((id) => !apps[id]!.app.settings.getBool('trackOnly'))
        .toList();
    var installedIds = <String>[];
    if (queuedIds.isNotEmpty) {
      AppLogger.info(
        'Server sync: installing or updating ${queuedIds.length} apps.',
      );
      try {
        installedIds = await downloadAndInstallLatestApps(
          queuedIds,
          context != null && context.mounted ? context : null,
        );
      } on MultiAppMultiError catch (e) {
        e.rawErrors.forEach(
          (id, err) => errors.add(id, err, appName: apps[id]?.name),
        );
      }
    }

    return ServerSyncResult(
      fromServer: fromServer,
      listed: entries.length,
      addedIds: addedIds,
      queuedIds: queuedIds,
      installedIds: installedIds,
      usingRoot: usingRoot,
      errors: errors,
    );
  }
}
