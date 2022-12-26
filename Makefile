serve:
	bundle exec jekyll serve --livereload --host 0.0.0.0

build:
	JEKYLL_ENV=production bundle exec jekyll build

