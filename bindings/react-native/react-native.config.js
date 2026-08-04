module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
      },
      ios: {
        podspecPath: __dirname + '/FoundryLocal.podspec',
      },
    },
  },
};
