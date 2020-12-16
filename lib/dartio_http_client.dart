import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'signalr_http_client.dart';
import 'utils.dart';
import 'package:logging/logging.dart';

class DartIOHttpClient extends SignalRHttpClient {
  // Properties

  final Logger _logger;

  // Methods

  DartIOHttpClient(Logger logger) : this._logger = logger;

  Future<SignalRHttpResponse> send(SignalRHttpRequest request) {
    // Check that abort was not signaled before calling send
    if ((request.abortSignal != null) && request.abortSignal.aborted) {
      return Future.error(AbortError());
    }

    if ((request.method == null) || (request.method.length == 0)) {
      return Future.error(new ArgumentError("No method defined."));
    }

    if ((request.url == null) || (request.url.length == 0)) {
      return Future.error(new ArgumentError("No url defined."));
    }

    return Future<SignalRHttpResponse>(() async {
      final uri = Uri.parse(request.url);

      final httpClient = new HttpClient();

      final abortFuture = Future<void>(() {
        final completer = Completer<void>();
        if (request.abortSignal != null) {
          request.abortSignal.onabort =
              () => completer.completeError(AbortError());
        }
        return completer.future;
      });

      if ((request.timeout != null) && (0 < request.timeout)) {
        httpClient.connectionTimeout = Duration(milliseconds: request.timeout);
      }

      _logger?.finest(
          "HTTP send: url '${request.url}', method: '${request.method}' content: '${request.content}'");

      final openFuture = Future<HttpClientRequest>(()
      {
        final completer = Completer<HttpClientRequest>();

        httpClient.openUrl(request.method, uri).then((r)
        {
          completer.complete(r);
        }).catchError((error)
        {
          completer.completeError(error);
        });

        return completer.future;
      });

      Exception httpError;
      final httpReqFuture = await Future.any([openFuture, abortFuture]).catchError((error){
        httpError = error;
      });

      if (httpError != null)
      {
        if (httpError is SocketException)
        {
          var socketException = httpError as SocketException;
          return Future.error(ConnectionError(socketException.message));
        }
        return Future.error(httpError);
      }

      final httpReq = httpReqFuture as HttpClientRequest;
      if (httpReq == null)
      {
        return Future.value(null);
      }

      httpReq.headers.set("X-Requested-With", "FlutterHttpClient");
      httpReq.headers.set("Content-Type", "text/plain;charset=UTF-8");
      if ((request.headers != null) && (!request.headers.isEmtpy)) {
        for (var name in request.headers.names) {
          httpReq.headers.set(name, request.headers.getHeaderValue(name));
        }
      }

			// TODO: IF you need to attach cookies, this is the place to do it, somehow.
			// if (request.cookies != null && !request.cookies.isEmpty)
			// 	httpReq.cookies = request.cookies;

      if (request.content != null) {
        httpReq.write(request.content);
      }

      final httpRespFuture = await Future.any([httpReq.close(), abortFuture]).catchError((error)
      {
        httpError = error;
      });

      if (httpError != null)
      {
        if (httpError is SocketException)
        {
          var socketException = httpError as SocketException;
          return Future.error(ConnectionError(socketException.message));
        }
        else if (httpError is HttpException)
        {
          var httpException = httpError as HttpException;
          return Future.error(ConnectionError(httpException.message));
        }
      }

      final httpResp = httpRespFuture as HttpClientResponse;
      if (httpResp == null) {
        return Future.value(null);
      }

      if (request.abortSignal != null) {
        request.abortSignal.onabort = null;
      }

      if ((httpResp.statusCode >= 200) && (httpResp.statusCode < 300)) {
        Object content;
        final contentTypeHeader = httpResp.headers["Content-Type"];
        final isJsonContent =
            contentTypeHeader.indexOf("application/json") != -1;
        if (isJsonContent) {
          content = await utf8.decoder.bind(httpResp).join();
        } else {
          content = await utf8.decoder.bind(httpResp).join();
          // When using SSE and the uri has an 'id' query parameter the response is not evaluated, otherwise it is an error.
          if (isStringEmpty(uri.queryParameters['id'])) {
            return Future.error(ArgumentError("Response Content-Type not supported: $contentTypeHeader"));
          }
        }

        return SignalRHttpResponse(httpResp.statusCode,statusText: httpResp.reasonPhrase, content: content,cookies:httpResp.cookies);
      } else {
        return Future.error(HttpError(httpResp.reasonPhrase, httpResp.statusCode));
      }
    });
  }
}
