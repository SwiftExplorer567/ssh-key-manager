export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Automated dependency updates contain generated changelog URLs and
    // metadata that can legitimately exceed the conventional 100-char body
    // limit. Keep conventional commit type/subject rules, but do not reject a
    // dependency PR solely because of generated body wrapping.
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
};
