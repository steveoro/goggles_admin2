#!/bin/bash

echo "Starting Spring, WebpackDevServer, the Rails webapp & the backend crawler server all at once..."
(trap 'kill 0' SIGINT; spring server & bin/webpack-dev-server & rails s & npm start & wait)
