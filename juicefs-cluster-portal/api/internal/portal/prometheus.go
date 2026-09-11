package portal

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type promSample struct {
	Metric    map[string]string
	Timestamp time.Time
	Value     float64
}

type promSeries struct {
	Metric map[string]string
	Points [][2]float64
}

type promAPI struct {
	base   *url.URL
	client *http.Client
}

type promWireResponse struct {
	Status    string `json:"status"`
	ErrorType string `json:"errorType"`
	Error     string `json:"error"`
	Data      struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string   `json:"metric"`
			Value  []json.RawMessage   `json:"value"`
			Values [][]json.RawMessage `json:"values"`
		} `json:"result"`
	} `json:"data"`
}

func newPromAPI(rawURL string, client *http.Client) (*promAPI, error) {
	base, err := url.Parse(rawURL)
	if err != nil || base.Scheme != "http" || base.Hostname() == "" {
		return nil, errors.New("invalid Prometheus URL")
	}
	if !isLoopbackHost(base.Hostname()) {
		return nil, errors.New("Prometheus URL must use loopback")
	}
	if client == nil {
		client = &http.Client{Timeout: 4 * time.Second}
	}
	return &promAPI{base: base, client: client}, nil
}

func isLoopbackHost(host string) bool {
	return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

func (p *promAPI) endpoint(path string, values url.Values) string {
	u := *p.base
	u.Path = strings.TrimRight(u.Path, "/") + path
	u.RawQuery = values.Encode()
	return u.String()
}

func (p *promAPI) request(ctx context.Context, path string, values url.Values) (promWireResponse, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, p.endpoint(path, values), nil)
	if err != nil {
		return promWireResponse{}, err
	}
	response, err := p.client.Do(request)
	if err != nil {
		return promWireResponse{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return promWireResponse{}, fmt.Errorf("Prometheus HTTP %d", response.StatusCode)
	}
	var payload promWireResponse
	decoder := json.NewDecoder(io.LimitReader(response.Body, 8<<20))
	if err := decoder.Decode(&payload); err != nil {
		return promWireResponse{}, fmt.Errorf("decode Prometheus response: %w", err)
	}
	if payload.Status != "success" {
		return promWireResponse{}, fmt.Errorf("Prometheus %s: %s", payload.ErrorType, payload.Error)
	}
	return payload, nil
}

func decodePromPair(pair []json.RawMessage) (time.Time, float64, error) {
	if len(pair) != 2 {
		return time.Time{}, 0, errors.New("invalid Prometheus sample")
	}
	var epoch float64
	var rawValue string
	if err := json.Unmarshal(pair[0], &epoch); err != nil {
		return time.Time{}, 0, err
	}
	if err := json.Unmarshal(pair[1], &rawValue); err != nil {
		return time.Time{}, 0, err
	}
	value, err := strconv.ParseFloat(rawValue, 64)
	if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
		return time.Time{}, 0, errors.New("invalid Prometheus value")
	}
	seconds, fraction := math.Modf(epoch)
	return time.Unix(int64(seconds), int64(fraction*1e9)).UTC(), value, nil
}

func (p *promAPI) query(ctx context.Context, expression string) ([]promSample, error) {
	payload, err := p.request(ctx, "/api/v1/query", url.Values{"query": {expression}})
	if err != nil {
		return nil, err
	}
	if payload.Data.ResultType != "vector" {
		return nil, fmt.Errorf("unexpected Prometheus result type %q", payload.Data.ResultType)
	}
	result := make([]promSample, 0, len(payload.Data.Result))
	for _, item := range payload.Data.Result {
		timestamp, value, err := decodePromPair(item.Value)
		if err != nil {
			return nil, err
		}
		result = append(result, promSample{Metric: item.Metric, Timestamp: timestamp, Value: value})
	}
	return result, nil
}

func (p *promAPI) queryRange(ctx context.Context, expression string, from, to time.Time, step int) ([]promSeries, error) {
	payload, err := p.request(ctx, "/api/v1/query_range", url.Values{
		"query": {expression},
		"start": {strconv.FormatInt(from.Unix(), 10)},
		"end":   {strconv.FormatInt(to.Unix(), 10)},
		"step":  {strconv.Itoa(step)},
	})
	if err != nil {
		return nil, err
	}
	if payload.Data.ResultType != "matrix" {
		return nil, fmt.Errorf("unexpected Prometheus result type %q", payload.Data.ResultType)
	}
	result := make([]promSeries, 0, len(payload.Data.Result))
	for _, item := range payload.Data.Result {
		series := promSeries{Metric: item.Metric}
		for _, pair := range item.Values {
			timestamp, value, err := decodePromPair(pair)
			if err != nil {
				return nil, err
			}
			series.Points = append(series.Points, [2]float64{float64(timestamp.Unix()), value})
		}
		result = append(result, series)
	}
	return result, nil
}

type namedQuery struct {
	Name       string
	Expression string
}

func (p *promAPI) batch(ctx context.Context, queries []namedQuery) (map[string][]promSample, error) {
	type item struct {
		name    string
		samples []promSample
		err     error
	}
	results := make(chan item, len(queries))
	semaphore := make(chan struct{}, 8)
	var wait sync.WaitGroup
	for _, query := range queries {
		query := query
		wait.Add(1)
		go func() {
			defer wait.Done()
			select {
			case semaphore <- struct{}{}:
				defer func() { <-semaphore }()
			case <-ctx.Done():
				results <- item{name: query.Name, err: ctx.Err()}
				return
			}
			samples, err := p.query(ctx, query.Expression)
			results <- item{name: query.Name, samples: samples, err: err}
		}()
	}
	wait.Wait()
	close(results)
	output := make(map[string][]promSample, len(queries))
	for result := range results {
		if result.err != nil {
			return nil, fmt.Errorf("query %s: %w", result.name, result.err)
		}
		output[result.name] = result.samples
	}
	return output, nil
}

func scalar(samples []promSample) (*float64, time.Time) {
	if len(samples) == 0 {
		return nil, time.Time{}
	}
	value := samples[0].Value
	return &value, samples[0].Timestamp
}

func sampleMap(samples []promSample, labels ...string) map[string]promSample {
	result := make(map[string]promSample, len(samples))
	for _, sample := range samples {
		parts := make([]string, len(labels))
		for index, label := range labels {
			parts[index] = sample.Metric[label]
		}
		result[strings.Join(parts, "\x00")] = sample
	}
	return result
}

func sampleValue(samples map[string]promSample, key string) *float64 {
	sample, ok := samples[key]
	if !ok {
		return nil
	}
	value := sample.Value
	return &value
}

func boolStatus(up *float64) string {
	if up == nil {
		return "unknown"
	}
	if *up == 1 {
		return "healthy"
	}
	return "unavailable"
}

func rounded(value *float64, digits int) *float64 {
	if value == nil {
		return nil
	}
	power := math.Pow10(digits)
	result := math.Round(*value*power) / power
	return &result
}
