# ----------- FASE 1: BUILD -----------
FROM dart:stable AS build

WORKDIR /app

# copia tudo
COPY . .

# instala dependências
RUN dart pub get

# compila o servidor para executável
# (ajusta o nome do ficheiro se for diferente)
RUN dart compile exe bin/server.dart -o server


# ----------- FASE 2: PRODUÇÃO -----------
FROM alpine:latest

# lib necessária para correr executáveis Dart
RUN apk add --no-cache libstdc++

WORKDIR /app

# copia apenas o executável da fase build
COPY --from=build /app/server /app/server

# porta default (podes trocar ou ignorar)
EXPOSE 8080

# comando final
CMD ["./server"]
