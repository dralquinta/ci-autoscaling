# Application Source Code Directory

**Place your application source code in this directory.**

This is where your actual application code lives. The Dockerfile in the parent directory will copy files from here during the build process.

## Structure Examples

### Node.js Application
```
application-source-code/
├── package.json
├── package-lock.json
├── server.js
├── src/
│   ├── routes/
│   ├── controllers/
│   └── models/
└── public/
```

### Python Application
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

### Java/Spring Boot
```
application-source-code/
├── pom.xml
├── src/
│   └── main/
│       ├── java/
│       └── resources/
└── target/
```

### Go Application
```
application-source-code/
├── go.mod
├── go.sum
├── main.go
├── handlers/
├── models/
└── middleware/
```

## Quick Start

### Option 1: Copy Your Existing Application
```bash
# Copy your application files to this directory
cp -r /path/to/your/app/* .

# Ensure you have the necessary dependency files:
# - package.json (Node.js)
# - requirements.txt (Python)
# - pom.xml (Java)
# - go.mod (Go)
# etc.
```

### Option 2: Use Provided Examples
```bash
# For Node.js
mv package.json.example package.json
mv server.js.example server.js

# For Python
mv requirements.txt.example requirements.txt
mv app.py.example app.py

# For Go
mv go.mod.example go.mod
mv main.go.example main.go

# For Java
mv pom.xml.example pom.xml
# Then create src/main/java/com/example/Application.java
```

See [EXAMPLES.md](EXAMPLES.md) for complete example applications.

## Instructions

1. **Add your application files** to this directory
2. **Ensure health check endpoint** - Your app MUST have a `/health` endpoint that returns HTTP 200
3. **Update parent Dockerfile** - Uncomment the appropriate runtime section in `../Dockerfile`
4. **Test locally** before deploying to OCI:
   ```bash
   cd ..
   docker build -t myapp:test .
   docker run -p 8080:8080 -e APP_PORT=8080 myapp:test
   curl http://localhost:8080/health
   ```

## Health Check Endpoint

Your application MUST implement a health check endpoint that returns HTTP 200.

### Examples

**Node.js (Express):**
```javascript
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});
```

**Python (Flask):**
```python
@app.route('/health')
def health():
    return {'status': 'healthy'}, 200
```

**Java (Spring Boot):**
```java
@GetMapping("/health")
public ResponseEntity<Map<String, String>> health() {
    return ResponseEntity.ok(Map.of("status", "healthy"));
}
```

**Go:**
```go
http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
})
```

## Environment Variables

Your application can access environment variables set in `app.env`:
- APP_PORT
- APP_ENV
- Any custom variables you add to deploy.sh

## Local Testing

Test your application locally before deploying:

```bash
# Build image
docker build -t my-app:test .

# Run container
docker run -p 8080:8080 my-app:test

# Test health endpoint
curl http://localhost:8080/health
```

---

**Note**: This directory is a placeholder. Replace with your actual application code.
