FROM node
MAINTAINER Octoblu, Inc. <docker@octoblu.com>

EXPOSE 80

WORKDIR /usr/src/app

ADD package.json /usr/src/app/
RUN npm install --production --silent
ADD . /usr/src/app/

CMD node octoblu-flow-canary.js
