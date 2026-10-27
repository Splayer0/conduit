import 'package:clock/clock.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/widgets/hermes_decision_card.dart';
import 'package:conduit/features/hermes/widgets/hermes_message_interactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DecisionConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'conversation',
    title: 'Conversation',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    metadata: const {'hermesSessionId': 'session'},
  );
}

class _DecisionMessages extends ChatMessagesNotifier {
  _DecisionMessages(this.messages);

  final List<ChatMessage> messages;

  @override
  List<ChatMessage> build() => messages;
}

void main() {
  test('selects the newest unresolved Hermes composer prompt', () {
    final approval = ChatMessage(
      id: 'approval',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: const {
        'transport': kHermesTransport,
        kHermesApprovalMeta: {
          'state': 'resolving',
          'runId': 'run',
          'approvalId': 'approval',
        },
      },
    );
    final decision = ChatMessage(
      id: 'decision',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'requestId': 'request',
          'runtimeId': 'runtime',
          'storedSessionId': 'session',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    expect(
      findPendingHermesComposerPrompt([approval, decision]),
      same(decision),
    );
  });

  test('selects a run-scoped clarify prompt without a Desktop session', () {
    final decision = ChatMessage(
      id: 'decision',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': 'clarification',
          'requestId': 'clr-1',
          'runtimeId': 'run-1',
          'runScoped': true,
          'prompt': 'Which host?',
          'expiresAt': DateTime.now()
              .add(const Duration(minutes: 3))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    // The runs API answers a clarify gate with the run that parked on it, so
    // no stored Desktop session is required to present the card.
    expect(findPendingHermesComposerPrompt([decision]), same(decision));

    final desktopShaped = decision.copyWith(
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': 'clarification',
          'requestId': 'clr-1',
          'runtimeId': 'run-1',
          'expiresAt': DateTime.now()
              .add(const Duration(minutes: 3))
              .toUtc()
              .toIso8601String(),
        },
      },
    );
    // A decision without either scope cannot be answered, so it stays hidden.
    expect(findPendingHermesComposerPrompt([desktopShaped]), isNull);
  });

  test('skips incomplete and archived newer Hermes prompts', () {
    final older = ChatMessage(
      id: 'older',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: const {
        'transport': kHermesTransport,
        kHermesApprovalMeta: {
          'state': 'pending',
          'runId': 'run',
          'approvalId': 'approval',
        },
      },
    );
    final incomplete = ChatMessage(
      id: 'incomplete',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: const {
        'transport': kHermesTransport,
        kHermesApprovalMeta: {'state': 'pending'},
      },
    );
    final archived = ChatMessage(
      id: 'archived',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: const {
        'transport': kHermesTransport,
        'archivedVariant': true,
        kHermesApprovalMeta: {
          'state': 'pending',
          'runId': 'archived-run',
          'approvalId': 'archived-approval',
        },
      },
    );

    expect(
      findPendingHermesComposerPrompt([older, incomplete, archived]),
      same(older),
    );
  });

  test('ignores resolved and expired Hermes prompts', () {
    ChatMessage message(String id, Map<String, dynamic> metadata) =>
        ChatMessage(
          id: id,
          role: 'assistant',
          content: '',
          timestamp: DateTime(2026),
          metadata: {'transport': kHermesTransport, ...metadata},
        );

    ChatMessage approval(String state) => message('approval', {
      kHermesApprovalMeta: {
        'state': state,
        'runId': 'run',
        'approvalId': 'approval',
      },
    });
    ChatMessage decision(Duration expiresIn) => message('decision', {
      kHermesDecisionMeta: {
        'state': 'pending',
        'requestId': 'request',
        'runtimeId': 'runtime',
        'storedSessionId': 'session',
        'expiresAt': clock.now().add(expiresIn).toUtc().toIso8601String(),
      },
    });

    expect(
      findPendingHermesComposerPrompt([
        approval('approved'),
        decision(const Duration(minutes: -1)),
      ]),
      isNull,
    );
    // Otherwise complete, so only the state and the expiry reject them.
    expect(findPendingHermesComposerPrompt([approval('pending')]), isNotNull);
    expect(
      findPendingHermesComposerPrompt([decision(const Duration(minutes: 1))]),
      isNotNull,
    );
  });

  testWidgets('an unrenderable approval cannot hide a pending decision', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'decision',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesApprovalMeta: const {
          'state': 'pending',
          'runId': 'missing-run',
          'approvalId': 'approval',
        },
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'requestId': 'request',
          'runtimeId': 'runtime',
          'storedSessionId': 'session',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_DecisionConversation.new),
        ],
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Theme(
            data: AppTheme.light(TweakcnThemes.t3Chat),
            child: HermesComposerPromptOverlay(message: message),
          ),
        ),
      ),
    );

    expect(find.text('Hermes needs clarification'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('an empty-id decision cannot hide an older valid prompt', (
    tester,
  ) async {
    ChatMessage decisionMessage({
      required String id,
      required String prompt,
      required String requestId,
      required String runtimeId,
      required String storedSessionId,
    }) => ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'prompt': prompt,
          'requestId': requestId,
          'runtimeId': runtimeId,
          'storedSessionId': storedSessionId,
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );
    final older = decisionMessage(
      id: 'older',
      prompt: 'Older valid prompt',
      requestId: 'request',
      runtimeId: 'runtime',
      storedSessionId: 'session',
    );
    final invalid = decisionMessage(
      id: 'invalid',
      prompt: 'Invalid newer prompt',
      requestId: '',
      runtimeId: '',
      storedSessionId: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_DecisionConversation.new),
          chatMessagesProvider.overrideWith(
            () => _DecisionMessages([older, invalid]),
          ),
        ],
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Theme(
            data: AppTheme.light(TweakcnThemes.t3Chat),
            child: HermesComposerPromptOverlay(message: older),
          ),
        ),
      ),
    );

    expect(find.text('Older valid prompt'), findsOneWidget);
    expect(find.text('Invalid newer prompt'), findsNothing);
  });

  testWidgets('a decision disappears when its wall-clock expiry passes', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'expiring',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'prompt': 'Short-lived prompt',
          'requestId': 'request',
          'runtimeId': 'runtime',
          'storedSessionId': 'session',
          'expiresAt': clock
              .now()
              .add(const Duration(minutes: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_DecisionConversation.new),
          chatMessagesProvider.overrideWith(() => _DecisionMessages(const [])),
        ],
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Theme(
            data: AppTheme.light(TweakcnThemes.t3Chat),
            child: HermesComposerPromptOverlay(message: message),
          ),
        ),
      ),
    );
    expect(find.text('Short-lived prompt'), findsOneWidget);

    await tester.pump(const Duration(seconds: 59));
    expect(find.text('Short-lived prompt'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Short-lived prompt'), findsNothing);
  });

  testWidgets('renders its response field in a Cupertino tree', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.clarification,
            onSubmit: (_) async => true,
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MCP setup uses explicit setup and decline actions', (
    tester,
  ) async {
    final answers = <String>[];
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.mcpSetup,
            mcpServer: 'github',
            mcpAction: 'authorize',
            onSubmit: (answer) async {
              answers.add(answer);
              return true;
            },
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.text('authorize github'), findsOneWidget);
    await tester.tap(find.text('Set up'));
    await tester.pump();
    expect(answers, ['approve']);
  });

  testWidgets('keeps the answer when submission fails', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.clarification,
            onSubmit: (_) async => false,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'keep this');
    await tester.tap(find.text('Send response'));
    await tester.pump();
    expect(find.text('keep this'), findsOneWidget);
  });

  testWidgets('submits the selected clarification choices', (tester) async {
    String? answer;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.clarification,
            choices: const ['alpha', 'beta'],
            multiSelect: true,
            onSubmit: (value) async {
              answer = value;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.tap(find.text('beta'));
    await tester.pump();
    await tester.tap(find.text('Send response'));
    await tester.pump();
    expect(answer, '["alpha","beta"]');
  });

  testWidgets('a run-scoped clarify card answers the run that parked on it', (
    tester,
  ) async {
    final interceptor = _ClarifyCaptureInterceptor();
    final service = HermesApiService(
      config: const HermesConfig(
        enabled: true,
        baseUrl: 'http://host:8642',
        apiKey: 'key',
      ),
      dio: Dio()..interceptors.add(interceptor),
    );
    final message = ChatMessage(
      id: 'clarify',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'prompt': 'Which host?',
          'requestId': 'clr-1',
          'runtimeId': 'run-1',
          // A runs-API question carries no Desktop session and answers
          // through POST /v1/runs/{id}/clarify instead.
          'runScoped': true,
          'executionGeneration': 7,
          'expiresAt': clock
              .now()
              .add(const Duration(minutes: 3))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_DecisionConversation.new),
          chatMessagesProvider.overrideWith(() => _DecisionMessages(const [])),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Theme(
            data: AppTheme.light(TweakcnThemes.t3Chat),
            child: HermesComposerPromptOverlay(message: message),
          ),
        ),
      ),
    );
    expect(find.text('Which host?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'the laptop');
    await tester.tap(find.text('Send response'));
    await tester.pumpAndSettle();

    final request = interceptor.requests.single;
    expect(request.method, 'POST');
    expect(request.path, 'http://host:8642/v1/runs/run-1/clarify');
    expect(request.data as Map<String, dynamic>, {
      'request_id': 'clr-1',
      'execution_generation': 7,
      'answer': 'the laptop',
    });
  });

  testWidgets('a run-scoped card without a generation is not presented', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'clarify',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'prompt': 'Unanswerable question',
          'requestId': 'clr-1',
          'runtimeId': 'run-1',
          'runScoped': true,
          'expiresAt': clock
              .now()
              .add(const Duration(minutes: 3))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_DecisionConversation.new),
          chatMessagesProvider.overrideWith(() => _DecisionMessages(const [])),
        ],
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Theme(
            data: AppTheme.light(TweakcnThemes.t3Chat),
            child: HermesComposerPromptOverlay(message: message),
          ),
        ),
      ),
    );

    // The runs API rejects a clarify answer without its generation, so the
    // card fails closed rather than offering a tap that can never succeed.
    expect(find.text('Unanswerable question'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}

class _ClarifyCaptureInterceptor extends Interceptor {
  final List<RequestOptions> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        data: const <String, dynamic>{},
        statusCode: 200,
      ),
    );
  }
}
