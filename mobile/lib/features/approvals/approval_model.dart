class ApprovalRequest {
  final String id;
  final String botId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? dangerLevel;

  ApprovalRequest({
    required this.id,
    required this.botId,
    required this.toolName,
    required this.arguments,
    this.dangerLevel,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    return ApprovalRequest(
      id: json['id'] as String,
      botId: json['botId'] as String,
      toolName: json['toolName'] as String,
      arguments: (json['arguments'] is Map)
          ? Map<String, dynamic>.from(json['arguments'] as Map)
          : {},
      dangerLevel: json['dangerLevel'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'botId': botId,
      'toolName': toolName,
      'arguments': arguments,
      if (dangerLevel != null) 'dangerLevel': dangerLevel,
    };
  }
}
