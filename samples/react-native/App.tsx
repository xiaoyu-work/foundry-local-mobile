/**
 * Foundry Local Mobile React Native example.
 *
 * @format
 */

import React, {useEffect, useRef, useState} from 'react';
import {
  ActivityIndicator,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  ChatSession,
  FoundryLocal,
  Model,
} from '@foundry-local/react-native';

type ChatMessage = {
  id: number;
  role: 'user' | 'assistant';
  text: string;
  thinking?: boolean;
};

function App(): React.JSX.Element {
  const [modelPath, setModelPath] = useState('');
  const [prompt, setPrompt] = useState('');
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [modelName, setModelName] = useState('Local model');
  const [status, setStatus] = useState(
    'Choose an ONNX Runtime GenAI model directory.',
  );
  const [isModelReady, setIsModelReady] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [isGenerating, setIsGenerating] = useState(false);

  const foundryRef = useRef<FoundryLocal | null>(null);
  const modelRef = useRef<Model | null>(null);
  const chatRef = useRef<ChatSession | null>(null);
  const listRef = useRef<FlatList<ChatMessage>>(null);
  const nextMessageId = useRef(0);
  const isMounted = useRef(true);

  useEffect(() => {
    isMounted.current = true;
    return () => {
      isMounted.current = false;
      chatRef.current?.close();
      modelRef.current?.close();
      foundryRef.current?.close();
      chatRef.current = null;
      modelRef.current = null;
      foundryRef.current = null;
    };
  }, []);

  const loadModel = async (): Promise<void> => {
    const path = modelPath.trim();
    if (!path) {
      setStatus('A model directory path is required.');
      return;
    }

    setIsLoading(true);
    setIsModelReady(false);
    setMessages([]);
    setModelName(path.split('/').filter(Boolean).pop() ?? 'Local model');
    setStatus('Loading model...');
    chatRef.current?.close();
    chatRef.current = null;
    modelRef.current?.close();
    modelRef.current = null;

    let loadedModel: Model | null = null;
    let loadedChat: ChatSession | null = null;
    try {
      let foundry = foundryRef.current;
      if (!foundry) {
        foundry = await FoundryLocal.create({
          appName: 'foundry-local-react-native-example',
        });
        if (!isMounted.current) {
          foundry.close();
          return;
        }
        foundryRef.current = foundry;
      }

      loadedModel = await foundry.loadModel(path);
      const info = loadedModel.getInfo();
      loadedChat = loadedModel.createChatSession({
        systemPrompt: 'You are a concise assistant.',
        temperature: 0.7,
        maxOutputTokens: 512,
      });

      if (!isMounted.current) {
        loadedChat.close();
        loadedModel.close();
        return;
      }

      modelRef.current = loadedModel;
      chatRef.current = loadedChat;
      setModelName(info.displayName || info.name);
      setStatus(
        `On-device - ${info.executionProvider || 'default EP'}`,
      );
      setIsModelReady(true);
    } catch (error) {
      loadedChat?.close();
      loadedModel?.close();
      if (isMounted.current) {
        setStatus(`Load failed: ${errorMessage(error)}`);
      }
    } finally {
      if (isMounted.current) {
        setIsLoading(false);
      }
    }
  };

  const sendPrompt = async (): Promise<void> => {
    const chat = chatRef.current;
    const text = prompt.trim();
    if (!chat) {
      setStatus('Load a model first.');
      return;
    }
    if (!text) {
      setStatus('Enter a prompt.');
      return;
    }
    if (isGenerating) {
      return;
    }

    const userId = nextMessageId.current++;
    const assistantId = nextMessageId.current++;
    setMessages(current => [
      ...current,
      {id: userId, role: 'user', text},
      {
        id: assistantId,
        role: 'assistant',
        text: '',
        thinking: true,
      },
    ]);
    setPrompt('');
    setIsGenerating(true);
    setStatus('Generating on device...');

    const updateAssistant = (
      update: (message: ChatMessage) => ChatMessage,
    ): void => {
      if (!isMounted.current) {
        return;
      }
      setMessages(current =>
        current.map(message =>
          message.id === assistantId ? update(message) : message,
        ),
      );
    };

    try {
      for await (const delta of chat.completeStreaming(text)) {
        if (!isMounted.current) {
          break;
        }
        updateAssistant(message => ({
          ...message,
          text: message.text + delta.text,
          thinking: false,
        }));
      }
      updateAssistant(message => ({
        ...message,
        text: message.text || 'No visible response was generated.',
        thinking: false,
      }));
      if (isMounted.current) {
        setStatus('On-device - Done');
      }
    } catch (error) {
      const detail = errorMessage(error);
      updateAssistant(message => ({
        ...message,
        text: message.text || `Generation failed: ${detail}`,
        thinking: false,
      }));
      if (isMounted.current) {
        setStatus(`Generation failed: ${detail}`);
      }
    } finally {
      if (isMounted.current) {
        setIsGenerating(false);
      }
    }
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar barStyle="dark-content" />
      {isModelReady ? (
        <KeyboardAvoidingView
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
          style={styles.chatScreen}>
          <ModelHeader
            busy={isGenerating}
            modelName={modelName}
            status={status}
          />
          <FlatList
            contentContainerStyle={
              messages.length === 0
                ? styles.emptyMessageList
                : styles.messageList
            }
            data={messages}
            keyExtractor={message => message.id.toString()}
            ListEmptyComponent={<EmptyConversation />}
            onContentSizeChange={() => {
              listRef.current?.scrollToEnd({animated: false});
            }}
            ref={listRef}
            renderItem={({item}) => <MessageBubble message={item} />}
            style={styles.messageListContainer}
            testID="message-list"
          />
          <ChatComposer
            enabled={!isGenerating}
            onChangeText={setPrompt}
            onSend={sendPrompt}
            value={prompt}
          />
        </KeyboardAvoidingView>
      ) : (
        <ModelSetup
          busy={isLoading}
          modelPath={modelPath}
          onChangePath={setModelPath}
          onLoad={loadModel}
          status={status}
        />
      )}
    </SafeAreaView>
  );
}

function ModelSetup({
  busy,
  modelPath,
  onChangePath,
  onLoad,
  status,
}: {
  busy: boolean;
  modelPath: string;
  onChangePath: (value: string) => void;
  onLoad: () => void;
  status: string;
}): React.JSX.Element {
  return (
    <ScrollView
      contentContainerStyle={styles.setupContainer}
      keyboardShouldPersistTaps="handled"
      testID="model-setup">
      <View style={styles.largeAvatar}>
        <Text style={styles.largeAvatarText}>AI</Text>
      </View>
      <Text style={styles.setupTitle}>Chat with a local model</Text>
      <Text style={styles.setupDescription}>
        Choose an ONNX Runtime GenAI model directory. Messages stay private
        and are generated on this device.
      </Text>
      <TextInput
        autoCapitalize="none"
        autoCorrect={false}
        editable={!busy}
        onChangeText={onChangePath}
        placeholder="/data/user/0/.../models/qwen3"
        placeholderTextColor="#94a3b8"
        style={styles.modelPathInput}
        testID="model-path-input"
        value={modelPath}
      />
      <TouchableOpacity
        accessibilityRole="button"
        disabled={busy || !modelPath.trim()}
        onPress={onLoad}
        style={[
          styles.loadButton,
          (busy || !modelPath.trim()) && styles.buttonDisabled,
        ]}
        testID="load-model-button">
        {busy && <ActivityIndicator color="#ffffff" />}
        <Text style={styles.loadButtonText}>
          {busy ? 'Loading...' : 'Load model'}
        </Text>
      </TouchableOpacity>
      <Text style={styles.setupStatus}>{status}</Text>
    </ScrollView>
  );
}

function ModelHeader({
  busy,
  modelName,
  status,
}: {
  busy: boolean;
  modelName: string;
  status: string;
}): React.JSX.Element {
  return (
    <View style={styles.modelHeader} testID="model-header">
      <View style={styles.avatar}>
        <Text style={styles.avatarText}>Q</Text>
      </View>
      <View style={styles.modelIdentity}>
        <Text numberOfLines={1} style={styles.modelName}>
          {modelName}
        </Text>
        <Text numberOfLines={1} style={styles.modelStatus}>
          {status}
        </Text>
      </View>
      {busy && <ActivityIndicator color="#10a37f" />}
    </View>
  );
}

function EmptyConversation(): React.JSX.Element {
  return (
    <View style={styles.emptyConversation}>
      <View style={styles.largeAvatar}>
        <Text style={styles.largeAvatarText}>Q</Text>
      </View>
      <Text style={styles.emptyTitle}>How can I help?</Text>
      <Text style={styles.emptyDescription}>
        Responses are generated locally on this device.
      </Text>
    </View>
  );
}

function MessageBubble({
  message,
}: {
  message: ChatMessage;
}): React.JSX.Element {
  const isUser = message.role === 'user';
  return (
    <View
      style={[
        styles.messageRow,
        isUser ? styles.userMessageRow : styles.assistantMessageRow,
      ]}
      testID={isUser ? 'user-message' : 'assistant-message'}>
      {!isUser && (
        <View style={styles.messageAvatar}>
          <Text style={styles.messageAvatarText}>Q</Text>
        </View>
      )}
      <View
        style={[
          styles.messageBubble,
          isUser ? styles.userBubble : styles.assistantBubble,
        ]}>
        {message.thinking ? (
          <View style={styles.thinking}>
            <ActivityIndicator color="#10a37f" size="small" />
            <Text style={styles.assistantText}>Thinking...</Text>
          </View>
        ) : (
          <Text
            selectable
            style={isUser ? styles.userText : styles.assistantText}>
            {message.text}
          </Text>
        )}
      </View>
    </View>
  );
}

function ChatComposer({
  enabled,
  onChangeText,
  onSend,
  value,
}: {
  enabled: boolean;
  onChangeText: (value: string) => void;
  onSend: () => void;
  value: string;
}): React.JSX.Element {
  const canSend = enabled && value.trim().length > 0;
  return (
    <View style={styles.composer} testID="chat-composer">
      <TextInput
        editable={enabled}
        multiline
        onChangeText={onChangeText}
        placeholder={enabled ? 'Message the model...' : 'Please wait...'}
        placeholderTextColor="#94a3b8"
        style={styles.chatInput}
        testID="chat-input"
        value={value}
      />
      <TouchableOpacity
        accessibilityLabel="Send"
        accessibilityRole="button"
        disabled={!canSend}
        onPress={onSend}
        style={[styles.sendButton, !canSend && styles.buttonDisabled]}
        testID="send-button">
        <Text style={styles.sendButtonText}>Send</Text>
      </TouchableOpacity>
    </View>
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

const styles = StyleSheet.create({
  safeArea: {
    backgroundColor: '#ffffff',
    flex: 1,
  },
  chatScreen: {
    flex: 1,
  },
  setupContainer: {
    alignItems: 'center',
    flexGrow: 1,
    justifyContent: 'center',
    padding: 24,
  },
  largeAvatar: {
    alignItems: 'center',
    backgroundColor: '#10a37f',
    borderRadius: 32,
    height: 64,
    justifyContent: 'center',
    width: 64,
  },
  largeAvatarText: {
    color: '#ffffff',
    fontSize: 22,
    fontWeight: '700',
  },
  setupTitle: {
    color: '#111827',
    fontSize: 26,
    fontWeight: '700',
    marginTop: 20,
    textAlign: 'center',
  },
  setupDescription: {
    color: '#64748b',
    fontSize: 16,
    lineHeight: 23,
    marginTop: 12,
    maxWidth: 520,
    textAlign: 'center',
  },
  modelPathInput: {
    backgroundColor: '#f1f5f9',
    borderColor: '#cbd5e1',
    borderRadius: 14,
    borderWidth: 1,
    color: '#0f172a',
    marginTop: 24,
    maxWidth: 520,
    paddingHorizontal: 14,
    paddingVertical: 13,
    width: '100%',
  },
  loadButton: {
    alignItems: 'center',
    backgroundColor: '#10a37f',
    borderRadius: 14,
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'center',
    marginTop: 14,
    maxWidth: 520,
    minHeight: 48,
    width: '100%',
  },
  buttonDisabled: {
    backgroundColor: '#94a3b8',
    opacity: 0.65,
  },
  loadButtonText: {
    color: '#ffffff',
    fontSize: 16,
    fontWeight: '700',
  },
  setupStatus: {
    color: '#64748b',
    fontSize: 13,
    marginTop: 16,
    maxWidth: 520,
    textAlign: 'center',
  },
  modelHeader: {
    alignItems: 'center',
    borderBottomColor: '#e2e8f0',
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    minHeight: 66,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  avatar: {
    alignItems: 'center',
    backgroundColor: '#10a37f',
    borderRadius: 20,
    height: 40,
    justifyContent: 'center',
    width: 40,
  },
  avatarText: {
    color: '#ffffff',
    fontSize: 17,
    fontWeight: '700',
  },
  modelIdentity: {
    flex: 1,
    marginHorizontal: 12,
  },
  modelName: {
    color: '#0f172a',
    fontSize: 16,
    fontWeight: '700',
  },
  modelStatus: {
    color: '#64748b',
    fontSize: 12,
    marginTop: 2,
  },
  messageListContainer: {
    flex: 1,
  },
  messageList: {
    gap: 16,
    padding: 16,
  },
  emptyMessageList: {
    flexGrow: 1,
  },
  emptyConversation: {
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
    padding: 32,
  },
  emptyTitle: {
    color: '#0f172a',
    fontSize: 24,
    fontWeight: '700',
    marginTop: 16,
  },
  emptyDescription: {
    color: '#64748b',
    fontSize: 15,
    marginTop: 8,
    textAlign: 'center',
  },
  messageRow: {
    alignItems: 'flex-start',
    flexDirection: 'row',
    width: '100%',
  },
  userMessageRow: {
    justifyContent: 'flex-end',
  },
  assistantMessageRow: {
    justifyContent: 'flex-start',
  },
  messageAvatar: {
    alignItems: 'center',
    backgroundColor: '#10a37f',
    borderRadius: 15,
    height: 30,
    justifyContent: 'center',
    marginRight: 10,
    width: 30,
  },
  messageAvatarText: {
    color: '#ffffff',
    fontSize: 12,
    fontWeight: '700',
  },
  messageBubble: {
    borderRadius: 20,
    maxWidth: '82%',
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  userBubble: {
    backgroundColor: '#10a37f',
  },
  assistantBubble: {
    backgroundColor: '#f1f5f9',
  },
  userText: {
    color: '#ffffff',
    fontSize: 16,
    lineHeight: 22,
  },
  assistantText: {
    color: '#0f172a',
    fontSize: 16,
    lineHeight: 22,
  },
  thinking: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  composer: {
    alignItems: 'flex-end',
    backgroundColor: '#ffffff',
    borderTopColor: '#e2e8f0',
    borderTopWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    gap: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  chatInput: {
    backgroundColor: '#f1f5f9',
    borderColor: '#cbd5e1',
    borderRadius: 22,
    borderWidth: 1,
    color: '#0f172a',
    flex: 1,
    maxHeight: 112,
    minHeight: 44,
    paddingHorizontal: 14,
    paddingVertical: 10,
    textAlignVertical: 'top',
  },
  sendButton: {
    alignItems: 'center',
    backgroundColor: '#10a37f',
    borderRadius: 22,
    height: 44,
    justifyContent: 'center',
    paddingHorizontal: 14,
  },
  sendButtonText: {
    color: '#ffffff',
    fontSize: 14,
    fontWeight: '700',
  },
});

export default App;
