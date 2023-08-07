FROM debian:bullseye-slim

RUN apt update && apt install -y ca-certificates-java openjdk-11-jre-headless openjdk-17-jre

# Build form https://github.com/spring-guides/gs-producing-web-service
ADD ./server.jar /

CMD [ "java", "-jar", "/server.jar" ]
