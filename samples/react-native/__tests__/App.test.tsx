/**
 * @format
 */

import {Text, View} from 'react-native';
import React from 'react';
import {afterEach, beforeEach, expect, it, jest} from '@jest/globals';

jest.mock('@foundry-local/react-native', () => ({
  ChatSession: class {},
  FoundryLocal: {create: jest.fn()},
  Model: class {},
}));

import App from '../App';

// Test renderer must be required after react-native.
import renderer, {act, ReactTestRenderer} from 'react-test-renderer';

type MockFunction = ReturnType<typeof jest.fn>;

const mockedSdk = jest.requireMock('@foundry-local/react-native') as {
  FoundryLocal: {create: MockFunction};
};
const mockCreate = mockedSdk.FoundryLocal.create;
const mockCompleteStreaming = jest.fn();
const mockChatClose = jest.fn();
const mockModelClose = jest.fn();
const mockFoundryClose = jest.fn();
const mockCreateChatSession = jest.fn();
const mockLoadModel = jest.fn();

let tree: ReactTestRenderer | undefined;

beforeEach(() => {
  jest.clearAllMocks();
  mockCreateChatSession.mockImplementation(() => ({
    close: mockChatClose,
    completeStreaming: mockCompleteStreaming,
  }));
  mockLoadModel.mockImplementation(async () => ({
    close: mockModelClose,
    createChatSession: mockCreateChatSession,
    getInfo: () => ({
      displayName: 'Qwen3 0.6B',
      executionProvider: 'CPUExecutionProvider',
      name: 'qwen3',
    }),
  }));
  mockCreate.mockImplementation(async () => ({
    close: mockFoundryClose,
    loadModel: mockLoadModel,
  }));
  mockCompleteStreaming.mockImplementation(async function* () {
    yield {text: 'Local '};
    yield {text: 'answer'};
  });
});

afterEach(() => {
  if (tree) {
    act(() => {
      tree?.unmount();
    });
    tree = undefined;
  }
});

it('starts with one-time model setup instead of chat diagnostics', () => {
  act(() => {
    tree = renderer.create(<App />);
  });

  expect(tree!.root.findByProps({testID: 'model-setup'})).toBeTruthy();
  expect(() =>
    tree!.root.findByProps({testID: 'chat-composer'}),
  ).toThrow();
});

it('switches to the model header, message list, and composer after loading', async () => {
  act(() => {
    tree = renderer.create(<App />);
  });

  await loadModel(tree!);

  expect(mockCreate).toHaveBeenCalledTimes(1);
  expect(mockLoadModel).toHaveBeenCalledWith('/models/qwen3');
  expect(mockCreateChatSession).toHaveBeenCalledTimes(1);
  expect(tree!.root.findByProps({testID: 'model-header'})).toBeTruthy();
  expect(tree!.root.findByProps({testID: 'message-list'})).toBeTruthy();
  expect(tree!.root.findByProps({testID: 'chat-composer'})).toBeTruthy();
  expect(renderedText(tree!)).toContain('Qwen3 0.6B');
});

it('keeps the user turn and streams text into an assistant message', async () => {
  act(() => {
    tree = renderer.create(<App />);
  });
  await loadModel(tree!);

  act(() => {
    tree!.root
      .findByProps({testID: 'chat-input'})
      .props.onChangeText('Hello');
  });
  await act(async () => {
    await tree!.root.findByProps({testID: 'send-button'}).props.onPress();
  });

  expect(mockCompleteStreaming).toHaveBeenCalledWith('Hello');
  const rendered = renderedText(tree!);
  expect(rendered).toContain('Hello');
  expect(rendered).toContain('Local answer');
  expect(
    tree!.root
      .findAllByType(View)
      .filter(node => node.props.testID === 'user-message'),
  ).toHaveLength(1);
  expect(
    tree!.root
      .findAllByType(View)
      .filter(node => node.props.testID === 'assistant-message'),
  ).toHaveLength(1);
});

async function loadModel(rendered: ReactTestRenderer): Promise<void> {
  act(() => {
    rendered.root
      .findByProps({testID: 'model-path-input'})
      .props.onChangeText('/models/qwen3');
  });
  expect(
    rendered.root.findByProps({testID: 'model-path-input'}).props.value,
  ).toBe('/models/qwen3');
  expect(
    rendered.root.findByProps({testID: 'load-model-button'}).props.disabled,
  ).toBe(false);
  await act(async () => {
    await rendered.root
      .findByProps({testID: 'load-model-button'})
      .props.onPress();
  });
}

function renderedText(rendered: ReactTestRenderer): string {
  return rendered.root
    .findAllByType(Text)
    .flatMap(node => node.props.children)
    .filter(child => typeof child === 'string')
    .join(' ');
}
