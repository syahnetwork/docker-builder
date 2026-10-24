FROM builder-hardened:latest
WORKDIR /build
COPY src ./src
RUN mkdir -p out && \
    javac -d out src/main/java/com/example/App.java && \
    jar --create --file out/app.jar --main-class com.example.App -C out .
CMD ["cp", "out/app.jar", "/out/app.jar"]