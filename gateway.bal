import ballerina/io;
import ballerina/http;
import ballerina/log;
import ai_gateway.llms;
import ai_gateway.analytics;
import ai_gateway.logging;
import ballerina/time;
import ballerina/uuid;

configurable llms:OpenAIConfig? & readonly openAIConfig = ();
configurable llms:AnthropicConfig? & readonly anthropicConfig = ();
configurable llms:GeminiConfig? & readonly geminiConfig = ();
configurable llms:OllamaConfig? & readonly ollamaConfig = ();
configurable llms:OpenAIConfig? & readonly mistralConfig = ();
configurable llms:OpenAIConfig? & readonly cohereConfig = ();

type GatewayConfig record {
    int port = 8080;
    int adminPort = 8081;
    boolean verboseLogging = false;
};

// Gateway configuration
configurable GatewayConfig gateway = {};

// Add system prompt storage
string systemPrompt = "";

// Add guardrails configuration type
type GuardrailConfig record {
    string[] bannedPhrases;
    int minLength;
    int maxLength;
    boolean requireDisclaimer;
    string disclaimer?;
};

// Add guardrails storage
GuardrailConfig guardrails = {
    bannedPhrases: [],
    minLength: 0,
    maxLength: 500000,
    requireDisclaimer: false
};

// Add guardrails processing function
function applyGuardrails(string text) returns string|error {
    if (text.length() < guardrails.minLength) {
        return error("Response too short. Minimum length: " + guardrails.minLength.toString());
    }
    string textRes = text;
    if (text.length() > guardrails.maxLength) {
        textRes = text.substring(0, guardrails.maxLength);
    }

    foreach string phrase in guardrails.bannedPhrases {
        if (text.toLowerAscii().includes(phrase)) {
            return error("Response contains banned phrase: " + phrase);
        }
    }

    if (guardrails.requireDisclaimer && guardrails.disclaimer != null) {
        textRes = text + "\n\n" + (guardrails.disclaimer ?: "");
    }

    return textRes;
}

// Add cache type and storage
type CacheEntry record {
    llms:LLMResponse response;
    int timestamp;
};

map<CacheEntry> promptCache = {};

// Add cache configuration
configurable int cacheTTLSeconds = 3600; // Default 1 hour TTL

// Using this to read initial logging configuration from system startup
// When the configurable is read from Config.toml at system startup, cannot assign or update
// that value later using the /admin service. So copying this at init()
configurable logging:LoggingConfig defaultLoggingConfig = {};

logging:LoggingConfig loggingConfig = {
    enableSplunk: false,
    enableDatadog: false,
    enableElasticSearch: false,
    openTelemetryEndpoint: "",
    splunkEndpoint: "",
    datadogEndpoint: "",
    elasticSearchEndpoint: "",
    elasticApiKey: ""
};

// Add logging state
boolean isVerboseLogging = gateway.verboseLogging;

function logEvent(string level, string component, string message, map<json> metadata = {}) {
    if (!isVerboseLogging && level == "DEBUG") {
        return;
    }

    // Create a copy of metadata to avoid modifying the original
    map<any> sanitizedMetadata = metadata.clone();

    // Mask sensitive data in metadata
    foreach string key in sanitizedMetadata.keys() {
        if (key.toLowerAscii().includes("apikey")) {
            sanitizedMetadata[key] = "********";
        }
    }

    json logEntry = {
        timestamp: time:utcToString(time:utcNow()),
        level: level,
        component: component,
        message: message,
        metadata: sanitizedMetadata.toString()
    };

    // Always log to console
    log:printInfo(logEntry.toString());

    // Publish to configured services
    if (loggingConfig.enableSplunk) {
        _ = start logging:publishToSplunk(loggingConfig, logEntry);
    }
    if (loggingConfig.enableDatadog) {
        _ = start logging:publishToDatadog(loggingConfig, logEntry);
    }
    if (loggingConfig.enableElasticSearch) {
        _ = start logging:publishToElasticSearch(loggingConfig, logEntry);
    }
}

// Add rate limiting types and storage
type RateLimitPlan record {|
    string name;
    int requestsPerWindow;
    int windowSeconds;
|};

type RateLimitState record {|
    int requests;
    int windowStart;
|};

// Store rate limit states by IP
map<RateLimitState> rateLimitStates = {};
RateLimitPlan? currentPlan = ();

// Add rate limiting function
function checkRateLimit(string clientIP) returns [boolean, int, int, int]|error {
    if currentPlan is () {
        return [true, 0, 0, 0];
    }

    RateLimitPlan plan = <RateLimitPlan>currentPlan;
    int currentTime = time:utcNow()[0];
    
    lock {
        RateLimitState state = rateLimitStates[clientIP] ?: {
            requests: 0,
            windowStart: currentTime
        };

        // Check if we need to reset window
        if (currentTime - state.windowStart >= plan.windowSeconds) {
            state = {
                requests: 0,
                windowStart: currentTime
            };
        }

        // Calculate remaining quota and time
        int remaining = plan.requestsPerWindow - state.requests;
        int resetSeconds = plan.windowSeconds - (currentTime - state.windowStart);
        
        if (state.requests >= plan.requestsPerWindow) {
            rateLimitStates[clientIP] = state;
            return [false, plan.requestsPerWindow, remaining, resetSeconds];
        }

        // Increment request count
        state.requests += 1;
        rateLimitStates[clientIP] = state;
        
        return [true, plan.requestsPerWindow, remaining - 1, resetSeconds];
    }
}

service / on new http:Listener(8080) {
    private http:Client? openaiClient = ();
    private http:Client? anthropicClient = ();
    private http:Client? geminiClient = ();
    private http:Client? ollamaClient = ();
    private http:Client? mistralClient = ();
    private http:Client? cohereClient = ();

    function init() returns error? {
        logEvent("INFO", "init", "Initializing AI Gateway");
        
        // Read initial logging configuration
        loggingConfig = defaultLoggingConfig;
        logEvent("DEBUG", "init", "Loaded logging configuration", <map<json>>loggingConfig.toJson());

        // Check if at least one provider is configured
        if openAIConfig == () && anthropicConfig == () && geminiConfig == () && ollamaConfig == () && mistralConfig == () && cohereConfig == () {
            logEvent("ERROR", "init", "No LLM providers configured");
            return error("At least one LLM provider must be configured");
        }

        if openAIConfig?.endpoint != () {
            string endpoint = openAIConfig?.endpoint ?: "";
            if (endpoint == "") {
                logEvent("ERROR", "init", "Invalid OpenAI configuration", {"error": "Empty endpoint"});
                return error("OpenAI endpoint is required");
            } else {
                self.openaiClient = check new (endpoint);
                logEvent("INFO", "init", "OpenAI client initialized", {"endpoint": endpoint});
            }
        }
        if anthropicConfig?.endpoint != () {
            string endpoint = anthropicConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Anthropic endpoint is required");
            } else {
                self.anthropicClient = check new (endpoint);
            }
        }
        if geminiConfig?.endpoint != () {
            string endpoint = geminiConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Gemini endpoint is required");
            } else {
                self.geminiClient = check new (endpoint);
            }
        }
        if ollamaConfig?.endpoint != () {
            string endpoint = ollamaConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Ollama endpoint is required");
            } else {
                self.ollamaClient = check new (endpoint);
            }
        }
        if mistralConfig?.endpoint != () {
            string endpoint = mistralConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Mistral endpoint is required");
            } else {
                self.mistralClient = check new (endpoint);
            }
        }
        if cohereConfig?.endpoint != () {
            string endpoint = cohereConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Cohere endpoint is required");
            } else {
                self.cohereClient = check new (endpoint);
            }
        }
        logEvent("INFO", "init", "AI Gateway initialization complete", {
            "providers": [
                openAIConfig != () ? "openai" : "",
                anthropicConfig != () ? "anthropic" : "",
                geminiConfig != () ? "gemini" : "",
                ollamaConfig != () ? "ollama" : "",
                mistralConfig != () ? "mistral" : "",
                cohereConfig != () ? "cohere" : ""
            ].filter(p => p != "")
        });
    }

    resource function post chat(@http:Header {name: "x-llm-provider"} string llmProvider, 
                              @http:Payload llms:LLMRequest payload,
                              http:Request request) returns error|http:Response|llms:LLMResponse {
        string|http:HeaderNotFoundError forwardedHeader = request.getHeader("X-Forwarded-For");

        // TODO: Use the client IP address from the request
        string clientIP = "";
        if forwardedHeader is string {
            clientIP = forwardedHeader;
        }
        // string clientIP = request.getHeader("X-Forwarded-For") ?: request.remoteAddress;
        
        // Check rate limit
        // [boolean allowed, int limit, int remaining, int reset] = check checkRateLimit(clientIP);
        [boolean, int, int, int] rateLimitResponse = check checkRateLimit(clientIP);
        boolean allowed = rateLimitResponse[0];
        int rateLimit = rateLimitResponse[1];
        int remaining = rateLimitResponse[2];
        int reset = rateLimitResponse[3];
        
        http:Response response = new;       
        if !allowed {
            response.statusCode = 429; // Too Many Requests
            response.setPayload({
                'error: "Rate limit exceeded",
                'limit: rateLimit,
                remaining: remaining,
                reset: reset
            });
            return response;
        }

        string requestId = uuid:createType1AsString();
        logEvent("INFO", "chat", "Received chat request", {
            requestId: requestId,
            provider: llmProvider,
            prompt: payload.prompt
        });

        // Check cache first
        string cacheKey = llmProvider + ":" + payload.prompt;
        if (promptCache.hasKey(cacheKey)) {
            logEvent("DEBUG", "cache", "Checking cache entry", {
                requestId: requestId,
                cacheKey: cacheKey
            });
            
            CacheEntry entry = promptCache.get(cacheKey);
            int currentTime = time:utcNow()[0];
            
            // Check if cache entry is still valid
            if (currentTime - entry.timestamp < cacheTTLSeconds) {
                logEvent("INFO", "cache", "Cache hit", {
                    requestId: requestId,
                    cacheKey: cacheKey
                });
                // Update cache stats
                lock {
                    requestStats.totalRequests += 1;
                    requestStats.cacheHits += 1;
                    requestStats.requestsByProvider[llmProvider] = (requestStats.requestsByProvider[llmProvider] ?: 0) + 1;
                    requestStats.successfulRequests += 1;
                    tokenStats.totalInputTokens += entry.response.input_tokens;
                    tokenStats.totalOutputTokens += entry.response.output_tokens;
                    tokenStats.inputTokensByProvider[llmProvider] = (tokenStats.inputTokensByProvider[llmProvider] ?: 0) + entry.response.input_tokens;
                    tokenStats.outputTokensByProvider[llmProvider] = (tokenStats.outputTokensByProvider[llmProvider] ?: 0) + entry.response.output_tokens;
                }
                http:Response cachedResponse = new;
                cachedResponse.setHeader("RateLimit-Limit", rateLimit.toString());
                cachedResponse.setHeader("RateLimit-Remaining", remaining.toString());
                cachedResponse.setHeader("RateLimit-Reset", reset.toString());
                cachedResponse.setPayload(entry.response);
                return cachedResponse;
            } else {
                logEvent("DEBUG", "cache", "Cache entry expired", {
                    requestId: requestId,
                    cacheKey: cacheKey,
                    age: currentTime - entry.timestamp
                });
                _ = promptCache.remove(cacheKey);
            }
        }

        // Cache miss
        logEvent("DEBUG", "cache", "Cache miss", {
            requestId: requestId,
            cacheKey: cacheKey
        });

        // Get list of available providers
        string[] availableProviders = [];
        if self.openaiClient != () {
            availableProviders.push("openai");
        }
        if self.anthropicClient != () {
            availableProviders.push("anthropic");
        }
        if self.geminiClient != () {
            availableProviders.push("gemini");
        }
        if self.ollamaClient != () {
            availableProviders.push("ollama");
        }
        if self.mistralClient != () {
            availableProviders.push("mistral");
        }
        if self.cohereClient != () {
            availableProviders.push("cohere");
        }

        // Only attempt failover if we have 2 or more providers
        boolean enableFailover = availableProviders.length() >= 2;
        
        // Try primary provider first
        llms:LLMResponse|error llmResponse = self.tryProvider(llmProvider, payload);
        
        if llmResponse is error && enableFailover {
            logEvent("WARN", "failover", "Primary provider failed", {
                requestId: requestId,
                provider: llmProvider,
                'error: llmResponse.message() + ":" + llmResponse.detail().toString()
            });
            
            // Try other providers
            foreach string provider in availableProviders {
                if provider != llmProvider {
                    logEvent("INFO", "failover", "Attempting failover", {
                        requestId: requestId,
                        provider: provider
                    });
                    
                    llms:LLMResponse|error failoverResponse = self.tryProvider(provider, payload);
                    if failoverResponse !is error {
                        logEvent("INFO", "failover", "Failover successful", {
                            requestId: requestId,
                            provider: provider
                        });
                        llmResponse = failoverResponse;
                        break;
                    }
                    logEvent("WARN", "failover", "Failover attempt failed", {
                        requestId: requestId,
                        provider: provider,
                        'error: failoverResponse.message() + ":" + failoverResponse.detail().toString()
                    });
                }
            }
        }

        if llmResponse is error {
            logEvent("ERROR", "chat", "All providers failed", {
                requestId: requestId,
                'error: llmResponse.message() + ":" + llmResponse.detail().toString()
            });
            return llmResponse;
        }

        // Cache successful response
        promptCache[cacheKey] = {
            response: llmResponse,
            timestamp: time:utcNow()[0]
        };
        logEvent("DEBUG", "cache", "Cached response", {
            requestId: requestId,
            cacheKey: cacheKey
        });

        // Add rate limit headers to response context
        response.setHeader("RateLimit-Limit", rateLimit.toString());
        response.setHeader("RateLimit-Remaining", remaining.toString());
        response.setHeader("RateLimit-Reset", reset.toString());
        response.setPayload(llmResponse);

        return response;
    }

    // Helper function to try a specific provider
    private function tryProvider(string provider, llms:LLMRequest payload) returns llms:LLMResponse|error {
        string requestId = uuid:createType1AsString();
        logEvent("DEBUG", "provider", "Attempting provider request", {
            requestId: requestId,
            provider: provider,
            prompt: payload.prompt
        });

        // Map of provider to client
        map<http:Client?> clientMap = {
            "openai": self.openaiClient,
            "anthropic": self.anthropicClient,
            "gemini": self.geminiClient,
            "ollama": self.ollamaClient,
            "mistral": self.mistralClient,
            "cohere": self.cohereClient
        };

        // Map of provider to handler function
        map<function (http:Client, llms:LLMRequest) returns llms:LLMResponse|error> handlerMap = {
            "openai": self.handleOpenAIRequest,
            "anthropic": self.handleAnthropicRequest,
            "gemini": self.handleGeminiRequest,
            "ollama": self.handleOllamaRequest,
            "mistral": self.handleMistralRequest,
            "cohere": self.handleCohereRequest
        };

        http:Client? llmClient = clientMap[provider];
        var handler = handlerMap[provider];

        if llmClient is http:Client && handler is function {
            llms:LLMResponse|error response = handler(llmClient, payload);
            if response is llms:LLMResponse {
                logEvent("INFO", "provider", "Provider request successful", {
                    requestId: requestId,
                    provider: provider,
                    model: response.model,
                    tokens: {
                        input: response.input_tokens,
                        output: response.output_tokens
                    }
                });
                // Update stats for successful request
                lock {
                    requestStats.totalRequests += 1;
                    requestStats.successfulRequests += 1;
                    requestStats.requestsByProvider[provider] = (requestStats.requestsByProvider[provider] ?: 0) + 1;
                    tokenStats.totalInputTokens += response.input_tokens;
                    tokenStats.totalOutputTokens += response.output_tokens;
                    tokenStats.inputTokensByProvider[provider] = (tokenStats.inputTokensByProvider[provider] ?: 0) + response.input_tokens;
                    tokenStats.outputTokensByProvider[provider] = (tokenStats.outputTokensByProvider[provider] ?: 0) + response.output_tokens;
                }
            }
            return response;
        }
        
        logEvent("ERROR", "provider", "Provider not configured", {
            requestId: requestId,
            provider: provider
        });
        return error("Provider not configured: " + provider);
    }

    private function handleOpenAIRequest(http:Client openaiClient, llms:LLMRequest req) returns llms:LLMResponse|error {
        string requestId = uuid:createType1AsString();
        
        if openAIConfig == () {
            logEvent("ERROR", "openai", "OpenAI not configured", {requestId});
            return error("OpenAI is not configured");
        }
        // Transform to OpenAI format
        json openAIPayload = {
            "model": openAIConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "temperature": req.temperature ?: 0.7,
            "max_tokens": req.maxTokens ?: 1000
        };

        if openAIConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (openAIConfig?.apiKey ?: "") };
            
            logEvent("DEBUG", "openai", "Sending request to OpenAI", {
                requestId,
                model: openAIConfig?.model ?: "",
                promptLength: req.prompt.length()
            });

            http:Response|error response = openaiClient->post("/v1/chat/completions", openAIPayload, headers);
            
            if response is error {
                logEvent("ERROR", "openai", "HTTP request failed", {
                    requestId,
                    'error: response.message() + ":" + response.detail().toString()
                });
                return response;
            }

            json|error responsePayload = response.getJsonPayload();
            if responsePayload is error {
                logEvent("ERROR", "openai", "Invalid JSON response", {
                    requestId,
                    'error: responsePayload.message() + ":" + responsePayload.detail().toString()
                });
                return responsePayload;
            }

            llms:OpenAIResponse|error openAIResponse = responsePayload.cloneWithType(llms:OpenAIResponse);
            if openAIResponse is error {
                logEvent("ERROR", "openai", "Response type conversion failed", {
                    requestId,
                    'error: openAIResponse.message() + ":" + openAIResponse.detail().toString()
                });
                return openAIResponse;
            }

            // Apply guardrails
            string|error guardedText = applyGuardrails(openAIResponse.choices[0].message.content);
            if guardedText is error {
                logEvent("ERROR", "guardrails", "Guardrails check failed", {
                    requestId,
                    'error: guardedText.message() + ":" + guardedText.detail().toString()
                });
                return guardedText;
            }

            return {
                text: guardedText,
                input_tokens: openAIResponse.usage.prompt_tokens,
                output_tokens: openAIResponse.usage.completion_tokens,
                model: openAIResponse.model,
                provider: "openai"
            };
        } else {
            logEvent("ERROR", "openai", "Invalid API key configuration", {requestId});
            return error("OpenAI configuration is invalid");
        }
    }

    private function handleOllamaRequest(http:Client ollamaClient, llms:LLMRequest req) returns llms:LLMResponse|error {
        if ollamaConfig == () {
            return error("Ollama is not configured");
        }
        json ollamaPayload = {
            "model": ollamaConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "stream": false
        };

        if ollamaConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (ollamaConfig?.apiKey ?: "") };

            http:Response response = check ollamaClient->post("/api/chat", ollamaPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Ollama response: " + responsePayload.toString());
            llms:OllamaResponse ollamaResponse = check responsePayload.cloneWithType(llms:OllamaResponse);

            // Apply guardrails before returning
            string guardedText = check applyGuardrails(ollamaResponse.message.content);
            return {
                text: guardedText,
                input_tokens: ollamaResponse.prompt_eval_count,
                output_tokens: ollamaResponse.eval_count,
                model: ollamaResponse.model,
                provider: "ollama"
            };
        } else {
            return error("Ollama configuration is invalid");
        }
    }    

    private function handleAnthropicRequest(http:Client anthropicClient, llms:LLMRequest req) returns llms:LLMResponse|error {
        if anthropicConfig == () {
            return error("Anthropic is not configured");
        }
        json anthropicPayload = {
            "model": anthropicConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "max_tokens": req.maxTokens ?: 1000
        };

        if anthropicConfig?.apiKey != "" {
            map<string|string[]> headers = { 
                "Authorization": "Bearer " + (anthropicConfig?.apiKey ?: ""),
                "anthropic-version": "2023-06-01"
            };
            http:Response response = check anthropicClient->post("/v1/messages", anthropicPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Anthropic response: " + responsePayload.toString());
            llms:AnthropicResponse anthropicResponse = check responsePayload.cloneWithType(llms:AnthropicResponse);
            
            // Apply guardrails before returning
            string guardedText = check applyGuardrails(anthropicResponse.contents.content[0].text);
            return {
                text: guardedText,
                input_tokens: anthropicResponse.usage.input_tokens,
                output_tokens: anthropicResponse.usage.output_tokens,
                model: anthropicResponse.model,
                provider: "anthropic"
            };
        } else {
            return error("Anthropic configuration is invalid");
        }
    }

    private function handleGeminiRequest(http:Client geminiClient, llms:LLMRequest req) returns llms:LLMResponse|error {
        if geminiConfig == () {
            return error("Gemini is not configured");
        }
        json geminiPayload = {
            "model": geminiConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "temperature": req.temperature ?: 0.7,
            "max_tokens": req.maxTokens ?: 1000
        };

        if geminiConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (geminiConfig?.apiKey ?: "") };

            http:Response response = check geminiClient->post(":chatCompletions", geminiPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Gemini response: " + responsePayload.toString());
            llms:OpenAIResponse openAIResponse = check responsePayload.cloneWithType(llms:OpenAIResponse);

            // Apply guardrails before returning
            string guardedText = check applyGuardrails(openAIResponse.choices[0].message.content);
            return {
                text: guardedText,
                input_tokens: 0,
                output_tokens: 0,
                model: openAIResponse.model,
                provider: "gemini"
            };
        } else {
            return error("Gemini configuration is invalid");
        }
    }

    private function handleMistralRequest(http:Client mistralClient, llms:LLMRequest req) returns llms:LLMResponse|error {
        if mistralConfig == () {
            return error("Mistral is not configured");
        }
        json mistralPayload = {
            "model": mistralConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user", 
                    "content": req.prompt
                }
            ],
            "temperature": req.temperature ?: 0.7,
            "max_tokens": req.maxTokens ?: 1000
        };

        if mistralConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (mistralConfig?.apiKey ?: "") };
            http:Response response = check mistralClient->post("/v1/chat/completions", mistralPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Mistral response: " + responsePayload.toString());
            llms:OpenAIResponse mistralResponse = check responsePayload.cloneWithType(llms:OpenAIResponse);

            // Apply guardrails before returning
            string guardedText = check applyGuardrails(mistralResponse.choices[0].message.content);
            return {
                text: guardedText,
                input_tokens: mistralResponse.usage.prompt_tokens,
                output_tokens: mistralResponse.usage.completion_tokens,
                model: mistralResponse.model,
                provider: "mistral"
            };
        } else {
            return error("Mistral configuration is invalid");
        }
    }

    private function handleCohereRequest(http:Client cohereClient, llms:LLMRequest req) returns llms:LLMResponse|error {
        if cohereConfig == () {
            return error("Cohere is not configured");
        }
        string cohereSystemPromt = "test";
        if (systemPrompt != "") {
            cohereSystemPromt = systemPrompt;
        }
        json coherePayload = {
            "message": req.prompt,
            "chat_history": [{
                "role": "USER",
                "message": req.prompt
            },
            {
                "role": "SYSTEM",
                "message": cohereSystemPromt
            }],  
            "temperature": req.temperature ?: 0.7, 
            "max_tokens": req.maxTokens ?: 1000,                     
            "model": cohereConfig?.model,
            "preamble": "You are an AI-assistant chatbot. You are trained to assist users by providing thorough and helpful responses to their queries."
        };

        if cohereConfig?.apiKey != "" {
            map<string|string[]> headers = { 
                "Authorization": "Bearer " + (cohereConfig?.apiKey ?: ""),
                "Content-Type": "application/json",
                "Accept": "application/json"
            };
            http:Response response = check cohereClient->post("/v1/chat", coherePayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Cohere response: " + responsePayload.toString());
            llms:CohereResponse cohereResponse = check responsePayload.cloneWithType(llms:CohereResponse);
            
            // Apply guardrails before returning
            string guardedText = check applyGuardrails(cohereResponse.text);
            return {
                text: guardedText,
                input_tokens: cohereResponse.meta.tokens.input_tokens,
                output_tokens: cohereResponse.meta.billed_units.output_tokens,
                model: cohereConfig?.model ?: "",
                provider: "cohere"
            };
        } else {
            return error("Cohere configuration is invalid");
        }
    }
}

// Analytics storage
analytics:RequestStats requestStats = {
    totalRequests: 0,
    successfulRequests: 0,
    failedRequests: 0,
    requestsByProvider: {},
    errorsByProvider: {},
    cacheHits: 0,
    cacheMisses: 0
};

analytics:TokenStats tokenStats = {
    totalInputTokens: 0,
    totalOutputTokens: 0,
    inputTokensByProvider: {},
    outputTokensByProvider: {}
};

analytics:ErrorStats errorStats = {
    totalErrors: 0,
    errorsByType: {},
    recentErrors: []
};

// Add new admin service
service /admin on new http:Listener(8081) {
    // Template HTML for analytics
    string statsTemplate = "";

    function init() returns error? {
        self.statsTemplate = check io:fileReadString("resources/stats.html");
    }
    resource function post systemprompt(@http:Payload llms:SystemPromptConfig config) returns string|error {
        systemPrompt = config.prompt;
        return "System prompt updated successfully";
    }

    resource function get systemprompt() returns llms:SystemPromptConfig {
        return {
            prompt: systemPrompt
        };
    }

    // Add guardrails endpoints
    resource function post guardrails(@http:Payload GuardrailConfig config) returns string|error {
        guardrails = config;
        return "Guardrails updated successfully";
    }

    resource function get guardrails() returns GuardrailConfig {
        return guardrails;
    }

    // Add cache management endpoints
    resource function delete cache() returns string {
        promptCache = {};
        return "Cache cleared successfully";
    }

    resource function get cache() returns map<CacheEntry> {
        return promptCache;
    }

    resource function get stats() returns http:Response|error {
        string[] requestLabels = [];
        int[] requestData = [];
        int i = 0;
        foreach string ikey in requestStats.requestsByProvider.keys() {
            requestLabels[i] = ikey;
            requestData[i] = requestStats.requestsByProvider[ikey] ?: 0;
            i = i + 1;
        }
        string[] inputTokenLabels = [];
        int[] inputTokenData = [];
        i = 0;
        foreach string ikey in tokenStats.inputTokensByProvider.keys() {
            inputTokenLabels[i] = ikey;
            inputTokenData[i] = tokenStats.inputTokensByProvider[ikey] ?: 0;
            i = i + 1;
        }
        int[] outputTokenData = [];
        i = 0;
        foreach string ikey in tokenStats.outputTokensByProvider.keys() {
            outputTokenData[i] = tokenStats.outputTokensByProvider[ikey] ?: 0;
            i = i + 1;
        }
        string[] errorLabels = [];
        int[] errorData = [];
        i = 0;
        foreach string ikey in errorStats.errorsByType.keys() {
            errorLabels[i] = ikey;
            errorData[i] = errorStats.errorsByType[ikey] ?: 0;
            i = i + 1;
        }

        // Calculate cache hit rate
        float cacheHitRate = 0.0;
        if (requestStats.totalRequests > 0) {
            cacheHitRate = <float>requestStats.cacheHits / <float>requestStats.totalRequests * 100.0;
        }

        // Prepare data for template
        map<string> templateValues = {
            "totalRequests": requestStats.totalRequests.toString(),
            "successfulRequests": requestStats.successfulRequests.toString(),
            "failedRequests": requestStats.failedRequests.toString(),
            "cacheHits": requestStats.cacheHits.toString(),
            "cacheMisses": requestStats.cacheMisses.toString(),
            "cacheHitRate": cacheHitRate.toFixedString(2) + "%",
            "totalInputTokens": tokenStats.totalInputTokens.toString(),
            "totalOutputTokens": tokenStats.totalOutputTokens.toString(),
            "totalErrors": errorStats.totalErrors.toString(),
            "recentErrors": "<li>" + string:'join("</li><li>", ...errorStats.recentErrors) + "</li>",
            "requestsLabels": requestLabels.toString(),
            "requestsData": requestData.toString(),
            "tokensLabels": inputTokenLabels.toString(),
            "inputTokensData": inputTokenData.toString(),
            "outputTokensData": outputTokenData.toString(),
            "errorLabels": errorLabels.toString(),
            "errorData": errorData.toString(),
            "cacheSize": promptCache.length().toString()
        };

        string html = analytics:renderTemplate(self.statsTemplate, templateValues);

        http:Response response = new;
        response.setHeader("Content-Type", "text/html");
        response.setPayload(html);
        return response;
    }

    // Add logging configuration endpoint
    resource function post logging(@http:Payload logging:LoggingConfig logConfig) returns string|error {
        loggingConfig = <logging:LoggingConfig & readonly>logConfig;
        return "Logging configuration updated successfully";
    }

    resource function get logging() returns logging:LoggingConfig {
        return loggingConfig;
    }

    // Add verbose logging toggle
    resource function post verbose(@http:Payload boolean enabled) returns string {
        isVerboseLogging = enabled;
        logEvent("INFO", "admin", "Verbose logging " + (enabled ? "enabled" : "disabled"));
        return "Verbose logging " + (enabled ? "enabled" : "disabled");
    }

    resource function get verbose() returns boolean {
        return isVerboseLogging;
    }

    // Get current rate limit plan
    resource function get ratelimit() returns RateLimitPlan? {
        return currentPlan;
    }

    // Update rate limit plan
    resource function post ratelimit(@http:Payload RateLimitPlan payload) returns string|error {
        lock {
            currentPlan = payload;
            // Clear existing states when plan changes
            rateLimitStates = {};
        }
        
        logEvent("INFO", "admin", "Rate limit plan updated", {
            plan: payload.toString()
        });
        
        return "Rate limit plan updated successfully";
    }

    // Remove rate limiting
    resource function delete ratelimit() returns string {
        lock {
            currentPlan = ();
            rateLimitStates = {};
        }
        
        logEvent("INFO", "admin", "Rate limiting disabled");
        
        return "Rate limiting disabled";
    }

    // Get current rate limit states (for debugging)
    resource function get ratelimit/states() returns map<RateLimitState> {
        return rateLimitStates;
    }
}
