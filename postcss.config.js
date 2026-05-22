module.exports = {
  parser: 'postcss-scss',
  plugins: [
    require('postcss-import')({
      path: ['assets/css'],
    }),
    require('@tailwindcss/postcss'),
    require('autoprefixer'),
    ...(process.env.JEKYLL_ENV == 'production'
      ? [require('cssnano')({ preset: 'default' })]
      : [])
  ]
}
