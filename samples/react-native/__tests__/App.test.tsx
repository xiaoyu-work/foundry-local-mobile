/**
 * @format
 */

import 'react-native';
import React from 'react';
import {it, jest} from '@jest/globals';

jest.mock('@foundry-local/react-native', () => ({
  FoundryLocal: {create: jest.fn()},
  Model: class {},
  ChatSession: class {},
}));

import App from '../App';

// Note: test renderer must be required after react-native.
import renderer from 'react-test-renderer';

it('renders correctly', () => {
  renderer.create(<App />);
});
