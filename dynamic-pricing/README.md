<div align="center">
   <img src="/img/logo.svg?raw=true" width=600 style="background-color:white;">
</div>

# Backend Engineering Take-Home Assignment: Dynamic Pricing Proxy

Welcome to the Tripla backend engineering take-home assignment\! 🧑‍💻 This exercise is designed to simulate a real-world problem you might encounter as part of our team.

⚠️ **Before you begin**, please review the main [FAQ](/README.md#frequently-asked-questions). It contains important information, **including our specific guidelines on how to submit your solution.**

## The Challenge

At Tripla, we use a dynamic pricing model for hotel rooms. Instead of static, unchanging rates, our model uses a real-time algorithm to adjust prices based on market demand and other data signals. This helps us maximize both revenue and occupancy.

Our Data and AI team built a powerful model to handle this, but its inference process is computationally expensive to run. To make this product more cost-effective, we analyzed the model's output and found that a calculated room rate remains effective for up to 5 minutes.

This insight presents a great optimization opportunity, and that's where you come in.

## Your Mission

Your mission is to build an efficient service that acts as an intermediary to our dynamic pricing model. This service will be responsible for providing rates to our users while respecting the operational constraints of the expensive model behind it.

You will start with a minimal Ruby on Rails application scaffold that currently returns a static price. You'll need to bring it to life.

## Core Requirements

1.  Integrate the Pricing Model: Modify the provided service to call the external dynamic pricing API to get the latest rates. The model is available as a Docker image: [tripladev/rate-api](https://hub.docker.com/r/tripladev/rate-api).

2.  Ensure Rate Validity: A rate fetched from the pricing model is considered valid for 5 minutes. Your service must ensure that any rate it provides for a given set of parameters (`period`, `hotel`, `room`) is no older than this 5-minute window.

3.  Honor API Usage Limits: The model's API token is limited. Your solution must be able to handle at least 10,000 requests per day from our users while using a single API token for the pricing model.

## How We'll Evaluate Your Work

This isn't just about getting the right answer. We're excited to see how you approach the problem. Treat this as you would a production-ready feature.

  * We'll be looking for clean, well-structured, and testable code. Feel free to add dependencies or refactor the existing scaffold as you see fit.
  * How do you decide on your approach to meeting the performance and cost requirements? Documenting your thought process is a great way to share this.
  * A reliable service anticipates failure. How does your service behave if the pricing model is slow, or returns an error? Providing descriptive error messages to the end-user is a key part of a robust API.
  * We want to see how you work around constraints and navigate an existing codebase to deliver a solution.


## Minimum Deliverables

1.  A link to your Git repository containing the complete solution.
2.  Clear instructions in the `README.md` on how to build, test, and run your service.

We highly value seeing your thought process. A great submission will also include documentation (e.g., in the `README.md`) discussing the design choices you made. Consider outlining different approaches you considered, their potential tradeoffs, and a clear rationale for why you chose your final solution.

## Development Environment Setup

The project scaffold is a minimal Ruby on Rails application with a `/pricing` endpoint. While you're free to configure your environment as you wish, this repository is pre-configured for a Docker-based workflow that supports live reloading for your convenience.

The provided `Dockerfile` builds a container with all necessary dependencies. Your local code is mounted directly into the container, so any changes you make on your machine will be reflected immediately. Your application will need to communicate with the external pricing model, which also runs in its own Docker container.

### Quick Start Guide

Here is a list of common commands for building, running, and interacting with the Dockerized environment.

```bash

# --- 1. Build & Run The Main Application ---
# Build the Docker image
docker build -t interview-app .

# Run the service
docker run -p 3000:3000 -v $(pwd):/rails interview-app

# --- 2. Test The Endpoint ---
# Send a sample request to your running service
curl 'http://localhost:3000/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# --- 3. Run Tests ---
# Run the development container in the background
docker run -d -p 3000:3000 -v $(pwd):/rails --name interview-dev interview-app

# Run the full test suite
docker container exec -it interview-dev ./bin/rails test

# Run a specific test file
docker container exec -it interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb

# Run a specific test by name
docker container exec -it interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb -n test_should_get_pricing_with_all_parameters
```

---

## Solution Implementation

### Quick Start

```bash
# Using Docker Compose (Recommended)
docker-compose up --build

# Test the endpoint
curl 'http://localhost:3000/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# Run tests
docker-compose run --rm app ./bin/rails test
```

### Architecture

Redis caching (5-min TTL) with three resilience patterns:
- **redis-mutex**: Distributed locking (prevents thundering herd)
- **circuitbox**: Circuit breaker (fails fast when API down)
- **Rack::Attack**: Rate limiting (100 req/min per IP)

Redis provides shared state across instances, atomic operations, and low latency.

Details in [IMPLEMENTATION.md](IMPLEMENTATION.md).

### Testing

```bash
# Run all tests
docker-compose run --rm app ./bin/rails test

# Check cache behavior
docker-compose exec redis redis-cli
> KEYS pricing:rate:*
```

### API Examples

```bash
# Valid request
curl 'http://localhost:3000/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
# {"rate":"15000"}

# Invalid parameter
curl 'http://localhost:3000/pricing?period=InvalidSeason&hotel=FloatingPointResort&room=SingletonRoom'
# {"error":"Invalid period. Must be one of: Summer, Autumn, Winter, Spring"}
```

### Configuration

Environment variables:

```bash
REDIS_URL=redis://localhost:6379/0
RATE_API_URL=http://rate-api:3001
RATE_API_TOKEN=your-api-token
```

---

Good luck, and we look forward to seeing what you build\!
