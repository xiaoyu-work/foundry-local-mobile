/**
 * Foundry Local Mobile React Native example.
 *
 * @format
 */

import React, {useEffect, useRef, useState} from 'react';
import {
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

function App(): React.JSX.Element {
  const [modelPath, setModelPath] = useState('');
  const [prompt, setPrompt] = useState(
    'In one sentence, what is on-device inference?',
  );
  const [response, setResponse] = useState('');
  const [status, setStatus] = useState(
    'Enter an ONNX Runtime GenAI model directory.',
  );
  const [isLoading, setIsLoading] = useState(false);
  const [isGenerating, setIsGenerating] = useState(false);

  const foundryRef = useRef<FoundryLocal | null>(null);
  const modelRef = useRef<Model | null>(null);
  const chatRef = useRef<ChatSession | null>(null);

  useEffect(() => {
    return () => {
      chatRef.current?.close();
      modelRef.current?.close();
      if (foundryRef.current) {
        foundryRef.current.close();
      }
    };
  }, []);

  const loadModel = async (): Promise<void> => {
    const path = modelPath.trim();
    if (!path) {
      setStatus('A model directory path is required.');
      return;
    }

    setIsLoading(true);
    setResponse('');
    setStatus('Loading model...');
    chatRef.current?.close();
    chatRef.current = null;
    modelRef.current?.close();
    modelRef.current = null;

    try {
      let foundry = foundryRef.current;
      if (!foundry) {
        foundry = await FoundryLocal.create({
          appName: 'foundry-local-react-native-example',
        });
        foundryRef.current = foundry;
      }

      const model = await foundry.loadModel(path);
      const info = model.getInfo();
      const chat = model.createChatSession({
        systemPrompt: 'You are a concise assistant.',
        temperature: 0.7,
        maxOutputTokens: 256,
      });
      modelRef.current = model;
      chatRef.current = chat;
      setStatus(
        `Ready: ${info.displayName || info.name} ` +
          `(${info.executionProvider || 'default EP'})`,
      );
    } catch (error) {
      setStatus(`Load failed: ${errorMessage(error)}`);
    } finally {
      setIsLoading(false);
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

    setIsGenerating(true);
    setResponse('');
    setStatus('Generating...');
    try {
      for await (const delta of chat.completeStreaming(text)) {
        setResponse(current => current + delta.text);
      }
      setStatus('Done.');
    } catch (error) {
      setStatus(`Generation failed: ${errorMessage(error)}`);
    } finally {
      setIsGenerating(false);
    }
  };

  const modelReady = chatRef.current !== null;
  const busy = isLoading || isGenerating;

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar barStyle="dark-content" />
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.title}>Foundry Local Mobile</Text>
        <Text style={styles.subtitle}>
          React Native path-only SDK example
        </Text>

        <View style={styles.card}>
          <Text style={styles.heading}>1. Local model</Text>
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            editable={!busy}
            onChangeText={setModelPath}
            placeholder="/data/user/0/.../models/qwen"
            style={styles.input}
            value={modelPath}
          />
          <ActionButton
            disabled={busy}
            label={isLoading ? 'Loading...' : 'Load model'}
            onPress={() => {
              loadModel();
            }}
          />
        </View>

        <View style={styles.card}>
          <Text style={styles.heading}>2. Streaming chat</Text>
          <TextInput
            editable={!busy}
            multiline
            onChangeText={setPrompt}
            style={[styles.input, styles.promptInput]}
            value={prompt}
          />
          <ActionButton
            disabled={!modelReady || busy}
            label={isGenerating ? 'Generating...' : 'Send'}
            onPress={() => {
              sendPrompt();
            }}
          />
          <Text selectable style={styles.response}>
            {response || 'The streamed response appears here.'}
          </Text>
        </View>

        <View style={styles.statusCard}>
          <Text style={styles.status}>{status}</Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

function ActionButton({
  disabled,
  label,
  onPress,
}: {
  disabled: boolean;
  label: string;
  onPress: () => void;
}): React.JSX.Element {
  return (
    <TouchableOpacity
      disabled={disabled}
      onPress={onPress}
      style={[styles.button, disabled && styles.buttonDisabled]}>
      <Text style={styles.buttonText}>{label}</Text>
    </TouchableOpacity>
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

const styles = StyleSheet.create({
  safeArea: {backgroundColor: '#f4f6fb', flex: 1},
  container: {gap: 16, padding: 20},
  title: {color: '#172554', fontSize: 30, fontWeight: '700'},
  subtitle: {color: '#475569', fontSize: 16, marginTop: -10},
  card: {
    backgroundColor: '#ffffff',
    borderRadius: 14,
    elevation: 2,
    gap: 12,
    padding: 16,
  },
  heading: {color: '#1e293b', fontSize: 18, fontWeight: '600'},
  input: {
    borderColor: '#94a3b8',
    borderRadius: 8,
    borderWidth: 1,
    color: '#0f172a',
    padding: 12,
  },
  promptInput: {minHeight: 84, textAlignVertical: 'top'},
  button: {
    alignItems: 'center',
    backgroundColor: '#4f46e5',
    borderRadius: 8,
    padding: 13,
  },
  buttonDisabled: {backgroundColor: '#a5b4fc'},
  buttonText: {color: '#ffffff', fontSize: 16, fontWeight: '600'},
  response: {
    backgroundColor: '#f8fafc',
    borderRadius: 8,
    color: '#0f172a',
    minHeight: 150,
    padding: 12,
  },
  statusCard: {backgroundColor: '#e0e7ff', borderRadius: 10, padding: 12},
  status: {color: '#312e81'},
});

export default App;
