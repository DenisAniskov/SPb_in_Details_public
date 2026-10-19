import 'package:smart_navigator_spb/services/assistant/assistant_consent_store.dart';

class MemoryAssistantConsentStore implements AssistantConsentStore {
  MemoryAssistantConsentStore({this.version});

  String? version;
  bool failRead = false;
  bool failAccept = false;
  bool failRevoke = false;
  int accepts = 0;
  int revokes = 0;

  @override
  Future<String?> readAcceptedVersion() async {
    if (failRead) throw StateError('read failed');
    return version;
  }

  @override
  Future<void> accept(String value) async {
    if (failAccept) throw StateError('accept failed');
    accepts++;
    version = value;
  }

  @override
  Future<void> revoke() async {
    if (failRevoke) throw StateError('revoke failed');
    revokes++;
    version = null;
  }
}
