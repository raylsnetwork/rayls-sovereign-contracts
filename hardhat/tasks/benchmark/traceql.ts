import http from 'node:http';
import https from 'node:https';
import { URL } from 'node:url';

export async function getJson(urlStr: string): Promise<any> {
    return new Promise((resolve, reject) => {
        const url = new URL(urlStr);
        const client = url.protocol === 'https:' ? https : http;
        const req = client.get(url, (res) => {
            let body = '';
            res.on('data', (chunk) => (body += chunk));
            res.on('end', () => {
                if ((res.statusCode || 0) >= 400) {
                    return reject(new Error(`Request to ${urlStr} failed: ${res.statusCode}`));
                }
                try {
                    resolve(JSON.parse(body));
                } catch (err) {
                    reject(err);
                }
            });
        });
        req.on('error', reject);
    });
}

export interface SpanDetail {
    name: string;
    startNano: number;
    endNano: number;
    durationNano: number;
    raw: string;
    scopeName: string;
    traceId: string;
    spanId: string;
    traceRequest: string;
    searchRequest: string;
    resourceId: string;
}

export interface TraceMetrics {
    traceId: string;
    graphanaUrl: string;
    serviceName: string;
    resourceId: string;
    traceRequest: string;
    searchRequest: string;
    [key: string]: number | string | bigint;
}

export async function collectTransferMetrics(
    tempoEndpoint: string,
    startTime_nano: bigint,
    endTime_nano: bigint,
    resourceId: string,
    serviceName: string,
    graphanaBaseUrl: string,
): Promise<TraceMetrics[]> {
    const traceRootName = 'enygma_send_transfer_pnh_event_span'
    const query = `{ resource.service.name = "${serviceName}" && trace:rootName = "${traceRootName}" && .resource_id = "${resourceId}" }`;
    const startTime_s = startTime_nano / BigInt(1_000_000_000);
    const endTime_s = endTime_nano / BigInt(1_000_000_000);
    const searchParams = new URLSearchParams({
        q: query,
        start: startTime_s.toString(),
        end: endTime_s.toString(),
        //spss: '10',
    });

    // 1) Fetch trace IDs
    const queryEndpoint = `${tempoEndpoint}/api/search?${searchParams}`
    console.log(`🔍 Searching for traces at ${queryEndpoint}`)
    const searchData = await getJson(`${queryEndpoint}`);
    const traceIDs: string[] = searchData.traces.map((t: any) => t.traceID);
    console.log('✅ Trace IDs:', traceIDs.join(', '));

    // 2) Fetch each trace's spans
    const allTraces: SpanDetail[][] = [];
    for (const id of traceIDs) {
        const tracesEndpoint = `${tempoEndpoint}/api/traces/${id}?start=${startTime_s.toString()}&end=${endTime_s.toString()}`
        console.log(`🔍 Querying traces details at ${tracesEndpoint}`)
        const traceData = await getJson(tracesEndpoint);
        //console.log(`✅ Traces details:\n${JSON.stringify(traceData, null, 2)}`);
        const spans: SpanDetail[] = [];

        for (const batch of traceData.batches) {
            for (const scopeSpan of batch.scopeSpans) {
                for (const span of scopeSpan.spans) {
                    const startNano = Number(span.startTimeUnixNano);
                    const endNano = Number(span.endTimeUnixNano);
                    const spanDetail: SpanDetail = {
                        name: span.name,
                        startNano,
                        endNano,
                        durationNano: endNano - startNano,
                        raw: JSON.stringify(span),
                        scopeName: scopeSpan.scope.name,
                        traceId: id,
                        spanId: span.spanId,
                        traceRequest: tracesEndpoint,
                        searchRequest: queryEndpoint,
                        resourceId,
                    }

                    spans.push(spanDetail);
                }
            }
        }

        allTraces.push(spans);
    }

    // 3) Map spans to metrics
    const namePrefixes: Record<string, string> = {
        enygma_send_transfer_pnh_event_span: 'enygma_send_transfer_pnh',
        get_enygma_key: 'get_enygma_key',
        generate_enygma_shared_secrets: 'generate_enygma_shared_secrets',
        generate_transfer_proof: 'generate_transfer_proof',
        encrypt_enygma_transfer_messages: 'encrypt_enygma_transfer_messages',
        send_enygma_transfer_transaction: 'send_enygma_transfer_transaction',
        mine_enygma_transfer_transaction: 'mine_enygma_transfer_transaction',
        send_enygma_pn_transfer_completed_transaction:
            'send_enygma_pn_transfer_completed',
        mine_enygma_pn_transfer_completed_transaction:
            'mine_enygma_pn_transfer_completed',
    };

    const graphanaUrl = `${graphanaBaseUrl}/a/grafana-exploretraces-app/explore?from=${(startTime_nano / BigInt(1_000_000)).toString()}&to=${(endTime_nano / BigInt(1_000_000)).toString()}&var-filters=trace:rootName%7C%3D%7C${traceRootName}&timezone=browser&var-ds=tempo&var-primarySignal=nestedSetParent<0&var-filters=.resource_id%7C%3D%7C${resourceId}&var-metric=rate&var-groupBy=resource.service.name&var-spanListColumns=&var-latencyThreshold=&var-partialLatencyThreshold=&actionView=traceList`

    const metrics: TraceMetrics[] = allTraces.map((spans, index) => {
        const traceGraphanaUrl = graphanaUrl + `&var-filters=trace:id%7C%3D%7C${spans[0].traceId}`
        const result: TraceMetrics = {
            traceId: spans[index].traceId,
            graphanaUrl: traceGraphanaUrl,
            serviceName,
            resourceId: spans[index].resourceId,
            traceRequest: spans[index].traceRequest,
            searchRequest: spans[index].searchRequest,
        };

        for (const [name, prefix] of Object.entries(namePrefixes)) {
            const span = spans.find((s) => s.name === name);
            if (span) {
                result[`${prefix}_start_time_nano`] = span.startNano;
                result[`${prefix}_end_time_nano`] = span.endNano;
                result[`${prefix}_duration_nano`] = span.durationNano;
            }
        }

        return result;
    });

    return metrics;
}
