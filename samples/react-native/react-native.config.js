const path = require('path');

module.exports = {
  dependencies: {
    '@foundry-local/react-native': {
      root: path.resolve(__dirname, '../../bindings/react-native'),
    },
  },
};
