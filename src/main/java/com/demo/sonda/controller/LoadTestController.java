package com.demo.sonda.controller;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

@RestController
@RequestMapping("/api")
public class LoadTestController {

    private static final Logger logger = LoggerFactory.getLogger(LoadTestController.class);
    private List<byte[]> memoryStore = new ArrayList<>();
    
    // Control flags for autoscaling scenarios
    private final AtomicBoolean healthCheckEnabled = new AtomicBoolean(true);
    private final AtomicBoolean cpuLoadActive = new AtomicBoolean(false);
    private final AtomicBoolean memoryLoadActive = new AtomicBoolean(false);
    private final ExecutorService executorService = Executors.newFixedThreadPool(4);
    private final List<Future<?>> activeTasks = new CopyOnWriteArrayList<>();

    @GetMapping("/health")
    public Map<String, String> health() {
        Map<String, String> response = new HashMap<>();
        response.put("status", "UP");
        response.put("timestamp", String.valueOf(System.currentTimeMillis()));
        return response;
    }

    @GetMapping("/cpu")
    public Map<String, Object> cpuLoad(@RequestParam(defaultValue = "1000") int iterations) {
        logger.info("CPU load test started with {} iterations", iterations);
        long startTime = System.currentTimeMillis();
        
        // CPU-intensive calculation
        double result = 0;
        for (int i = 0; i < iterations * 1000; i++) {
            result += Math.sqrt(i) * Math.sin(i) * Math.cos(i);
        }
        
        long endTime = System.currentTimeMillis();
        Map<String, Object> response = new HashMap<>();
        response.put("message", "CPU load test completed");
        response.put("iterations", iterations * 1000);
        response.put("duration_ms", endTime - startTime);
        response.put("result", result);
        
        logger.info("CPU load test completed in {} ms", endTime - startTime);
        return response;
    }

    @GetMapping("/memory")
    public Map<String, Object> memoryLoad(@RequestParam(defaultValue = "10") int sizeMB) {
        logger.info("Memory load test started with {} MB", sizeMB);
        long startTime = System.currentTimeMillis();
        
        // Allocate memory (1MB = 1024 * 1024 bytes)
        int bytesToAllocate = sizeMB * 1024 * 1024;
        byte[] memoryBlock = new byte[bytesToAllocate];
        
        // Fill with some data to ensure allocation
        for (int i = 0; i < Math.min(bytesToAllocate, 1000); i++) {
            memoryBlock[i] = (byte) (i % 256);
        }
        
        memoryStore.add(memoryBlock);
        
        long endTime = System.currentTimeMillis();
        Runtime runtime = Runtime.getRuntime();
        
        Map<String, Object> response = new HashMap<>();
        response.put("message", "Memory allocated");
        response.put("allocated_mb", sizeMB);
        response.put("duration_ms", endTime - startTime);
        response.put("total_memory_mb", runtime.totalMemory() / (1024 * 1024));
        response.put("used_memory_mb", (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        response.put("free_memory_mb", runtime.freeMemory() / (1024 * 1024));
        
        logger.info("Memory allocated: {} MB in {} ms", sizeMB, endTime - startTime);
        return response;
    }

    @DeleteMapping("/memory")
    public Map<String, Object> clearMemory() {
        logger.info("Clearing memory store");
        int size = memoryStore.size();
        memoryStore.clear();
        System.gc();
        
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> response = new HashMap<>();
        response.put("message", "Memory cleared");
        response.put("blocks_cleared", size);
        response.put("total_memory_mb", runtime.totalMemory() / (1024 * 1024));
        response.put("used_memory_mb", (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        response.put("free_memory_mb", runtime.freeMemory() / (1024 * 1024));
        
        logger.info("Memory cleared: {} blocks", size);
        return response;
    }

    @GetMapping("/combined")
    public Map<String, Object> combinedLoad(
            @RequestParam(defaultValue = "500") int cpuIterations,
            @RequestParam(defaultValue = "5") int memoryMB) {
        
        logger.info("Combined load test started: CPU={} iterations, Memory={} MB", cpuIterations, memoryMB);
        long startTime = System.currentTimeMillis();
        
        // CPU load
        double cpuResult = 0;
        for (int i = 0; i < cpuIterations * 1000; i++) {
            cpuResult += Math.sqrt(i) * Math.sin(i);
        }
        
        // Memory load
        byte[] memoryBlock = new byte[memoryMB * 1024 * 1024];
        for (int i = 0; i < Math.min(memoryBlock.length, 1000); i++) {
            memoryBlock[i] = (byte) (i % 256);
        }
        memoryStore.add(memoryBlock);
        
        long endTime = System.currentTimeMillis();
        Runtime runtime = Runtime.getRuntime();
        
        Map<String, Object> response = new HashMap<>();
        response.put("message", "Combined load test completed");
        response.put("cpu_iterations", cpuIterations * 1000);
        response.put("memory_allocated_mb", memoryMB);
        response.put("duration_ms", endTime - startTime);
        response.put("used_memory_mb", (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        
        logger.info("Combined load test completed in {} ms", endTime - startTime);
        return response;
    }

    @GetMapping("/info")
    public Map<String, Object> getInfo() {
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> info = new HashMap<>();
        info.put("application", "Autoscaling Demo");
        info.put("version", "1.0.0");
        info.put("container_name", System.getenv().getOrDefault("HOSTNAME", "unknown"));
        info.put("processors", runtime.availableProcessors());
        info.put("total_memory_mb", runtime.totalMemory() / (1024 * 1024));
        info.put("free_memory_mb", runtime.freeMemory() / (1024 * 1024));
        info.put("used_memory_mb", (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        info.put("max_memory_mb", runtime.maxMemory() / (1024 * 1024));
        info.put("cpu_load_active", cpuLoadActive.get());
        info.put("memory_load_active", memoryLoadActive.get());
        info.put("health_check_enabled", healthCheckEnabled.get());
        return info;
    }

    // ========== USE CASE 1: CPU-based Autoscaling (>60% CPU utilization) ==========
    
    @PostMapping("/scenario/cpu/start")
    public Map<String, Object> startCpuLoad(
            @RequestParam(defaultValue = "60") int targetCpuPercent,
            @RequestParam(defaultValue = "300") int durationSeconds) {
        
        if (cpuLoadActive.get()) {
            Map<String, Object> response = new HashMap<>();
            response.put("status", "error");
            response.put("message", "CPU load scenario is already running");
            return response;
        }
        
        cpuLoadActive.set(true);
        logger.info("Starting CPU load scenario: target={}%, duration={}s", targetCpuPercent, durationSeconds);
        
        // Start CPU load in background threads
        int numCores = Runtime.getRuntime().availableProcessors();
        for (int i = 0; i < numCores; i++) {
            Future<?> task = executorService.submit(() -> {
                long endTime = System.currentTimeMillis() + (durationSeconds * 1000L);
                while (cpuLoadActive.get() && System.currentTimeMillis() < endTime) {
                    // CPU-intensive work
                    double result = 0;
                    for (int j = 0; j < 1000000; j++) {
                        result += Math.sqrt(j) * Math.sin(j) * Math.cos(j);
                    }
                    // Brief pause to achieve target CPU percentage
                    try {
                        Thread.sleep((100 - targetCpuPercent) * 10L);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            });
            activeTasks.add(task);
        }
        
        // Schedule automatic stop
        executorService.submit(() -> {
            try {
                Thread.sleep(durationSeconds * 1000L);
                stopCpuLoad();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
        
        Map<String, Object> response = new HashMap<>();
        response.put("status", "started");
        response.put("message", "CPU load scenario started");
        response.put("target_cpu_percent", targetCpuPercent);
        response.put("duration_seconds", durationSeconds);
        response.put("cores_used", numCores);
        return response;
    }
    
    @PostMapping("/scenario/cpu/stop")
    public Map<String, Object> stopCpuLoad() {
        cpuLoadActive.set(false);
        activeTasks.forEach(task -> task.cancel(true));
        activeTasks.clear();
        
        logger.info("CPU load scenario stopped");
        
        Map<String, Object> response = new HashMap<>();
        response.put("status", "stopped");
        response.put("message", "CPU load scenario stopped");
        return response;
    }
    
    // ========== USE CASE 2: Memory-based Autoscaling (>60% memory utilization) ==========
    
    @PostMapping("/scenario/memory/start")
    public Map<String, Object> startMemoryLoad(
            @RequestParam(defaultValue = "70") int targetMemoryPercent,
            @RequestParam(defaultValue = "300") int durationSeconds) {
        
        if (memoryLoadActive.get()) {
            Map<String, Object> response = new HashMap<>();
            response.put("status", "error");
            response.put("message", "Memory load scenario is already running");
            return response;
        }
        
        memoryLoadActive.set(true);
        logger.info("Starting memory load scenario: target={}%, duration={}s", targetMemoryPercent, durationSeconds);
        
        Runtime runtime = Runtime.getRuntime();
        long maxMemory = runtime.maxMemory();
        long targetMemory = (maxMemory * targetMemoryPercent) / 100;
        
        // Allocate memory to reach target percentage
        executorService.submit(() -> {
            try {
                while (memoryLoadActive.get() && 
                       (runtime.totalMemory() - runtime.freeMemory()) < targetMemory) {
                    // Allocate 10MB chunks
                    byte[] chunk = new byte[10 * 1024 * 1024];
                    // Fill with data to ensure allocation
                    for (int i = 0; i < chunk.length; i += 1024) {
                        chunk[i] = (byte) (i % 256);
                    }
                    memoryStore.add(chunk);
                    Thread.sleep(100);
                }
                
                // Hold the memory for the duration
                Thread.sleep(durationSeconds * 1000L);
                stopMemoryLoad();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
        
        Map<String, Object> response = new HashMap<>();
        response.put("status", "started");
        response.put("message", "Memory load scenario started");
        response.put("target_memory_percent", targetMemoryPercent);
        response.put("duration_seconds", durationSeconds);
        response.put("max_memory_mb", maxMemory / (1024 * 1024));
        response.put("target_memory_mb", targetMemory / (1024 * 1024));
        return response;
    }
    
    @PostMapping("/scenario/memory/stop")
    public Map<String, Object> stopMemoryLoad() {
        memoryLoadActive.set(false);
        memoryStore.clear();
        
        logger.info("Memory load scenario stopped");
        
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> response = new HashMap<>();
        response.put("status", "stopped");
        response.put("message", "Memory load scenario stopped and cleared");
        response.put("current_memory_mb", (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        response.put("max_memory_mb", runtime.maxMemory() / (1024 * 1024));
        return response;
    }
    
    // ========== USE CASE 3: Health Check Failure-based Autoscaling ==========
    
    @PostMapping("/scenario/health/fail")
    public Map<String, Object> failHealthCheck(
            @RequestParam(defaultValue = "300") int durationSeconds) {
        
        healthCheckEnabled.set(false);
        logger.warn("Health check failure scenario started for {}s", durationSeconds);
        
        // Schedule automatic recovery
        executorService.submit(() -> {
            try {
                Thread.sleep(durationSeconds * 1000L);
                recoverHealthCheck();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
        
        Map<String, Object> response = new HashMap<>();
        response.put("status", "failing");
        response.put("message", "Health checks will now fail");
        response.put("duration_seconds", durationSeconds);
        return response;
    }
    
    @PostMapping("/scenario/health/recover")
    public Map<String, Object> recoverHealthCheck() {
        healthCheckEnabled.set(true);
        logger.info("Health check recovered");
        
        Map<String, Object> response = new HashMap<>();
        response.put("status", "recovered");
        response.put("message", "Health checks restored to normal");
        return response;
    }
    
    @GetMapping("/scenario/health/status")
    public ResponseEntity<Map<String, Object>> healthCheckStatus() {
        Map<String, Object> response = new HashMap<>();
        
        if (!healthCheckEnabled.get()) {
            response.put("status", "DOWN");
            response.put("message", "Health check failure scenario active");
            logger.warn("Health check returning DOWN status");
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(response);
        }
        
        // Simulate random failures or timeouts (10% chance)
        if (Math.random() < 0.1) {
            if (Math.random() < 0.5) {
                // Simulate timeout
                try {
                    Thread.sleep(10000); // 10 second timeout
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            response.put("status", "DOWN");
            response.put("message", "Random failure");
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(response);
        }
        
        response.put("status", "UP");
        response.put("timestamp", System.currentTimeMillis());
        return ResponseEntity.ok(response);
    }
    
    @GetMapping("/scenario/status")
    public Map<String, Object> getScenarioStatus() {
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> status = new HashMap<>();
        status.put("cpu_scenario_active", cpuLoadActive.get());
        status.put("memory_scenario_active", memoryLoadActive.get());
        status.put("health_check_enabled", healthCheckEnabled.get());
        status.put("current_cpu_cores", runtime.availableProcessors());
        status.put("current_memory_used_mb", (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        status.put("current_memory_max_mb", runtime.maxMemory() / (1024 * 1024));
        status.put("current_memory_percent", 
            ((runtime.totalMemory() - runtime.freeMemory()) * 100) / runtime.maxMemory());
        return status;
    }
}
