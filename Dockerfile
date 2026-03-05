FROM node:18

WORKDIR /lab2

COPY . .

RUN npm install
