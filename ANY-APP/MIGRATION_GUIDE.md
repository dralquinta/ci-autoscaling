# Migration Guide: application-source-code Directory Structure

## What Changed

The ANY-APP template has been refactored to use a dedicated `application-source-code/` directory for all application code. This provides better separation between deployment infrastructure and application code.

## New Directory Structure

```
ANY-APP/
├── Dockerfile.template           # References application-source-code/
├── deploy.sh                     # Validates application-source-code/ exists
├── docker-compose.yml.template   # Build context points to ANY-APP root
├── .dockerignore                 # Optimizes build context
├── app.env.template              # Configuration (unchanged)
│
├── application-source-code/      # 🆕 YOUR APPLICATION CODE GOES HERE
│   ├── README.md                 # Instructions
│   ├── EXAMPLES.md               # Example applications
│   ├── .gitignore                # Git ignore for app code
│   ├── package.json.example      # Node.js example
│   ├── server.js.example         # Node.js example
│   ├── requirements.txt.example  # Python example
│   ├── app.py.example            # Python example
│   ├── go.mod.example            # Go example
│   ├── main.go.example           # Go example
│   ├── pom.xml.example           # Java example
│   └── (your actual app files)
│
├── scripts/                      # Deployment scripts (unchanged)
└── autoscaling/                  # Autoscaling config (unchanged)
```

## Key Changes

### 1. Dockerfile.template
All `COPY` commands now reference `application-source-code/`:
- **Before**: `COPY package*.json ./`
- **After**: `COPY application-source-code/package*.json ./`

### 2. deploy.sh
Added validation to check if `application-source-code/` directory exists before building.

### 3. New Files Created
- `application-source-code/EXAMPLES.md` - Complete example applications
- `application-source-code/.gitignore` - Git ignore for application code
- `application-source-code/*.example` - Example files for different runtimes
- `.dockerignore` - Optimizes Docker build context

### 4. Documentation Updated
- `README.md` - Updated quick start with application-source-code
- `QUICKSTART.md` - Added step for adding application code
- `INDEX.md` - Updated directory structure
- `OVERVIEW.md` - Updated quick start guide

## Migration Steps

### For New Projects

1. **Add your application code:**
   ```bash
   cd ANY-APP/application-source-code/
   cp -r /path/to/your/app/* .
   ```

2. **Or use examples:**
   ```bash
   cd ANY-APP/application-source-code/
   mv package.json.example package.json  # Node.js
   mv server.js.example server.js
   ```

3. **Configure Dockerfile:**
   ```bash
   cd ..
   cp Dockerfile.template Dockerfile
   # Edit and uncomment your runtime section
   vi Dockerfile
   ```

4. **Deploy:**
   ```bash
   source app.env
   ./deploy.sh --build-and-push
   ./deploy.sh --deploy
   ```

### For Existing Projects (If You Had Old Structure)

If you previously had application code directly in the ANY-APP directory:

1. **Move your application code:**
   ```bash
   cd ANY-APP
   mkdir -p application-source-code
   mv package.json server.js src/ application-source-code/  # Node.js example
   # OR
   mv requirements.txt app.py src/ application-source-code/  # Python example
   # OR
   mv pom.xml src/ application-source-code/  # Java example
   ```

2. **Update your Dockerfile** (if you have a custom one):
   ```dockerfile
   # Change:
   COPY package*.json ./
   # To:
   COPY application-source-code/package*.json ./
   
   # Change:
   COPY . .
   # To:
   COPY application-source-code/ .
   ```

3. **Test the build:**
   ```bash
   docker build -t myapp:test .
   docker run -p 8080:8080 -e APP_PORT=8080 myapp:test
   ```

## Benefits of This Structure

✅ **Clear Separation**: Deployment infrastructure vs. application code  
✅ **Better .gitignore**: Can ignore deployment files while tracking app code  
✅ **Reusability**: Easy to swap different applications  
✅ **Build Optimization**: .dockerignore only includes necessary files  
✅ **Examples Included**: Multiple runtime examples to get started  
✅ **Template Friendly**: Clone and replace application-source-code/  

## Example Workflows

### Workflow 1: Deploy Multiple Apps
```bash
# App 1
cd ANY-APP-1/application-source-code/
cp -r ~/projects/api-service/* .
cd ..
./deploy.sh --build-and-push --deploy

# App 2 (same infrastructure, different app)
cd ANY-APP-2/application-source-code/
cp -r ~/projects/web-app/* .
cd ..
./deploy.sh --build-and-push --deploy
```

### Workflow 2: Use Examples
```bash
cd ANY-APP/application-source-code/
mv package.json.example package.json
mv server.js.example server.js
cd ..
cp Dockerfile.template Dockerfile
# Edit Dockerfile, uncomment Node.js section
./deploy.sh --build-and-push --deploy
```

### Workflow 3: CI/CD Integration
```yaml
# .github/workflows/deploy.yml
- name: Copy application code
  run: |
    cp -r ${{ github.workspace }}/src/* ci-autoscaling/ANY-APP/application-source-code/

- name: Deploy
  run: |
    cd ci-autoscaling/ANY-APP
    source app.env
    ./deploy.sh --build-and-push --deploy
```

## Troubleshooting

### Build fails with "No such file or directory"
**Cause**: Application code not in `application-source-code/`  
**Solution**: 
```bash
ls application-source-code/  # Verify files exist
# Copy your app files if missing
cp -r /path/to/app/* application-source-code/
```

### Docker COPY fails in build
**Cause**: Dockerfile not updated to reference `application-source-code/`  
**Solution**: Update all COPY commands in your Dockerfile:
```dockerfile
COPY application-source-code/package*.json ./
COPY application-source-code/ .
```

### Health check fails
**Cause**: Your application doesn't have a `/health` endpoint  
**Solution**: Add a health check endpoint to your application (see examples in EXAMPLES.md)

## Questions?

See the following documentation:
- `application-source-code/README.md` - How to add your code
- `application-source-code/EXAMPLES.md` - Complete examples
- `README.md` - Full deployment guide
- `QUICKSTART.md` - Quick start guide

## Summary

The new structure provides a clean separation between deployment infrastructure (Dockerfile, deploy scripts, autoscaling) and application code (in `application-source-code/`). This makes the template more reusable and easier to understand.

All Dockerfiles now reference `application-source-code/` as the source, and the build process validates this directory exists before proceeding.
