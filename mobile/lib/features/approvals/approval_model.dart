class ApprovalRequest {
  final String id;
  final String botId;
  final String threadId;
  final String requestId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? dangerLevel;
  final String? messageId;

  ApprovalRequest({
    required this.id,
    required this.botId,
    required this.threadId,
    required this.requestId,
    required this.toolName,
    required this.arguments,
    this.dangerLevel,
    this.messageId,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    return ApprovalRequest(
      id: json['id'] as String? ?? json['requestId'] as String? ?? '',
      botId: json['botId'] as String? ?? '',
      threadId: json['threadId'] as String? ?? '',
      requestId: json['requestId'] as String? ?? json['id'] as String? ?? '',
      toolName: json['toolName'] as String? ?? json['tool'] as String? ?? 'tool',
      arguments: (json['arguments'] is Map)
          ? Map<String, dynamic>.from(json['arguments'] as Map)
          : {},
      dangerLevel: json['dangerLevel'] as String?,
      messageId: json['messageId'] as String?,
    );
  }

  factory ApprovalRequest.fromWireMessage({
    required String botId,
    required String threadId,
    required Map<String, dynamic> message,
  }) {
    final card = message['card'];
    final cardMap = card is Map ? Map<String, dynamic>.from(card) : <String, dynamic>{};
    final requestId = cardMap['requestId'] as String? ?? message['id'] as String? ?? '';
    final tool = cardMap['tool'] as String? ?? cardMap['title'] as String? ?? 'tool';
    final subtitle = cardMap['subtitle'] as String?;
    return ApprovalRequest(
      id: requestId,
      botId: botId,
      threadId: threadId,
      requestId: requestId,
      toolName: tool,
      arguments: {
        if (subtitle != null && subtitle.isNotEmpty) 'detail': subtitle,
      },
      dangerLevel: cardMap['held'] as String?,
      messageId: message['id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'botId': botId,
      'threadId': threadId,
      'requestId': requestId,
      'toolName': toolName,
      'arguments': arguments,
      if (dangerLevel != null) 'dangerLevel': dangerLevel,
      if (messageId != null) 'messageId': messageId,
    };
  }
}
