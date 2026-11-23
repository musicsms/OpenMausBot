import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../core/theme/grok_theme.dart';
import '../approvals/approval_card.dart';
import '../approvals/approval_model.dart';
import '../bots/avatar_pulse.dart';
import 'chat_message.dart';

class ChatView extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isStreaming;
  final ValueChanged<String> onSendMessage;
  final String connectionLabel;
  final ApprovalRequest? pendingApproval;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  const ChatView({
    super.key,
    required this.messages,
    required this.isStreaming,
    required this.onSendMessage,
    this.connectionLabel = 'Online',
    this.pendingApproval,
    this.onApprove,
    this.onReject,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _scrollToBottom() {
    if (!mounted) return;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _handleSend() {
    final text = _inputController.text.trim();
    if (text.isNotEmpty) {
      HapticFeedback.lightImpact();
      widget.onSendMessage(text);
      _inputController.clear();
    }
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasNewMessage = widget.messages.length != oldWidget.messages.length;
    final approvalChanged = widget.pendingApproval?.id != oldWidget.pendingApproval?.id;
    final isNearBottom = !_scrollController.hasClients ||
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 60;

    if (hasNewMessage || approvalChanged || (widget.isStreaming && isNearBottom)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToBottom();
        }
      });
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GrokTheme.oledBlack,
      appBar: AppBar(
        backgroundColor: GrokTheme.oledBlack,
        elevation: 0,
        title: Row(
          children: [
            AvatarPulse(isThinking: widget.isStreaming, size: 36),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Nibble', style: TextStyle(color: Colors.white, fontSize: 16)),
                Text(
                  widget.connectionLabel,
                  style: const TextStyle(color: GrokTheme.approvalGreen, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: widget.messages.length + (widget.pendingApproval != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (widget.pendingApproval != null && index == widget.messages.length) {
                  return ApprovalCard(
                    request: widget.pendingApproval!,
                    onApprove: widget.onApprove ?? () {},
                    onReject: widget.onReject ?? () {},
                  );
                }

                final msg = widget.messages[index];
                final isUser = msg.role == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(14),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                    decoration: BoxDecoration(
                      color: isUser ? GrokTheme.darkCharcoal : const Color(0xFF161922),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: GrokTheme.slateBorder),
                    ),
                    child: MarkdownBody(
                      data: msg.content,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                        code: const TextStyle(color: GrokTheme.glowCyan, backgroundColor: Colors.transparent),
                        codeblockDecoration: BoxDecoration(
                          color: GrokTheme.oledBlack,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: GrokTheme.slateBorder),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: GrokTheme.darkCharcoal,
              border: Border(top: BorderSide(color: GrokTheme.slateBorder)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _handleSend(),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Nhập tin nhắn...',
                        hintStyle: TextStyle(color: GrokTheme.textMuted),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: Colors.white),
                    onPressed: _handleSend,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
