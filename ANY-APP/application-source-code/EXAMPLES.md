# Application Source Code Examples

This directory contains example files for different application types. Rename the `.example` files by removing the `.example` extension and customize them for your application.

## Quick Start

### Node.js Application
```bash
mv package.json.example package.json
mv server.js.example server.js
npm install
npm start
```

### Python Application
```bash
mv requirements.txt.example requirements.txt
mv app.py.example app.py
pip install -r requirements.txt
python app.py
```

### Go Application
```bash
mv go.mod.example go.mod
mv main.go.example main.go
go mod tidy
go run main.go
```

### Java/Spring Boot Application
```bash
mv pom.xml.example pom.xml
# Create src/main/java/com/example/Application.java
mvn spring-boot:run
```

## Important Notes

1. **Health Check Endpoint**: All examples include a `/health` endpoint that returns HTTP 200. This is required for OCI Container Instances health checks.

2. **Port Configuration**: Applications read the port from the `APP_PORT` environment variable, which is set in `app.env`.

3. **Listen on 0.0.0.0**: Applications must listen on `0.0.0.0` (all interfaces), not just `localhost`, to be accessible from outside the container.

4. **Dockerfile**: Make sure to uncomment the appropriate section in `Dockerfile` that matches your application type.

## File Structure

For production applications, organize your code properly:

### Node.js
```
application-source-code/
├── package.json
├── server.js
├── src/
│   ├── routes/
│   ├── controllers/
│   └── models/
└── tests/
```

### Python
```
application-source-code/
├── requirements.txt
├── app.py
├── src/
│   ├── routes/
│   ├── models/
│   └── utils/
└── tests/
```

### Java
```
application-source-code/
├── pom.xml
└── src/
    └── main/
        ├── java/
        │   └── com/example/
        └── resources/
            └── application.properties
```

### Go
```
application-source-code/
├── go.mod
├── go.sum
├── main.go
├── handlers/
├── models/
└── tests/
```

## Testing Locally

Before deploying to OCI, test your application locally:

```bash
# From the ANY-APP directory
docker build -t myapp:test .
docker run -p 8080:8080 -e APP_PORT=8080 myapp:test

# Test health endpoint
curl http://localhost:8080/health
```

## Next Steps

1. Copy your application code to this directory
2. Update the `Dockerfile` in the parent directory
3. Configure `app.env` with your settings
4. Run `./deploy.sh --build-and-push`
5. Run `./deploy.sh --deploy`
