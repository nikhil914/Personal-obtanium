import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/apps_provider_server_sync.dart';
import 'package:provider/provider.dart';

bool _serverSyncRunning = false;

bool get isServerSyncRunning => _serverSyncRunning;

Future<ServerSyncResult?> runServerSync(
  BuildContext context, {
  bool reportWhenNothingToDo = false,
}) async {
  if (_serverSyncRunning) return null;
  _serverSyncRunning = true;
  final appsProvider = context.read<AppsProvider>();
  try {
    final result = await appsProvider.syncFromServer(context: context);
    if (!context.mounted) return result;
    if (result.hasErrors) {
      showError(result.errors, context);
    } else if (result.addedIds.isNotEmpty ||
        result.queuedIds.isNotEmpty ||
        reportWhenNothingToDo) {
      showMessage(
        result.fromServer
            ? tr(
                'serverSyncSummary',
                args: [
                  result.listed.toString(),
                  result.addedIds.length.toString(),
                  result.installedIds.length.toString(),
                ],
              )
            : tr(
                'autoInstallSummary',
                args: [result.installedIds.length.toString()],
              ),
        context,
      );
    }
    return result;
  } catch (e) {
    if (context.mounted) showError(e, context);
    return null;
  } finally {
    _serverSyncRunning = false;
  }
}
