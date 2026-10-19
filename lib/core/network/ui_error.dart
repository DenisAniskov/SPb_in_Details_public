import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';

String placesUiError(Object error) {
  debugPrint('Places failure: ${error.runtimeType}');
  if (error is FormatException ||
      error is TypeError ||
      (error is DioException &&
          (error.error is FormatException || error.error is TypeError))) {
    return 'Сервер вернул неполный или некорректный каталог. Попробуйте обновить.';
  }
  if (error is DioException) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return 'Время ожидания ответа от сервера истекло. Попробуйте обновить.';
    }
    if (error.type == DioExceptionType.connectionError) {
      return 'Не удалось подключиться к серверу API. Проверьте соединение или адрес сервера.';
    }
    final status = error.response?.statusCode;
    if (status == 404) {
      return 'Запрашиваемые данные не найдены на сервере.';
    }
    if (status != null && status >= 500) {
      return 'Сервер временно недоступен. Попробуйте позже.';
    }
  } else if (error is SocketException) {
    return 'Не удалось подключиться к серверу API. Проверьте соединение или адрес сервера.';
  } else if (error is TimeoutException) {
    return 'Время ожидания ответа от сервера истекло. Попробуйте обновить.';
  }

  final str = error.toString().toLowerCase();
  if (str.contains('connection refused') ||
      str.contains('socketexception') ||
      str.contains('failed host lookup') ||
      str.contains('connecttimeout') ||
      str.contains('connection error')) {
    return 'Не удалось подключиться к серверу API. Проверьте соединение или адрес сервера.';
  } else if (str.contains('receivetimeout') ||
      str.contains('sendtimeout') ||
      str.contains('timeout')) {
    return 'Время ожидания ответа от сервера истекло. Попробуйте обновить.';
  } else if (str.contains('404')) {
    return 'Запрашиваемые данные не найдены на сервере.';
  } else if (str.contains('500') ||
      str.contains('502') ||
      str.contains('503')) {
    return 'Сервер временно недоступен. Попробуйте позже.';
  }

  return 'Не удалось загрузить данные. Проверьте соединение с сетью.';
}

String routeUiError(Object error, {required bool walk}) {
  debugPrint('Routing failure: ${error.runtimeType}');
  if (error is RouteCalculationFailure) {
    switch (error.kind) {
      case RouteFailureKind.pedestrianUnavailable:
        return 'Пешеходный маршрут к выбранным местам не найден. Измените точку отправления или выберите другие места.';
      case RouteFailureKind.nativeBudgetExceeded:
        return 'Проверенные пешеходные маршруты с осмотром не помещаются в выбранное время. Измените точку отправления или выберите прогулку подольше.';
      case RouteFailureKind.requestLimitReached:
        return 'Достигнут лимит проверки вариантов прогулки. Измените точку отправления или попробуйте подобрать маршрут ещё раз.';
      case RouteFailureKind.invalidResponse:
        return 'Не удалось проверить время пешеходного маршрута. Попробуйте построить маршрут ещё раз.';
      case RouteFailureKind.noMeaningfulRoute:
        return 'Пешеходный маршрут имеет нулевую длину. Измените точку отправления или выберите другие места для прогулки.';
      case RouteFailureKind.mixedNativeConstraints:
        return 'Часть проверенных пешеходных маршрутов недоступна, остальные не помещаются в выбранное время с осмотром. Измените старт, места или выберите прогулку подольше.';
      case RouteFailureKind.serviceUnavailable:
        return 'Сервис пешеходных маршрутов Яндекса временно недоступен. Проверьте сеть и попробуйте ещё раз.';
    }
  }
  if (error is TimeoutException || error is SocketException) {
    return 'Нет ответа от сервиса пешеходных маршрутов. Проверьте сеть и попробуйте ещё раз.';
  }
  if (error is StateError &&
      error.message.startsWith('Даже одно подходящее место')) {
    return error.message;
  }
  return walk
      ? 'Не удалось построить прогулку. Проверьте сеть и попробуйте ещё раз.'
      : 'Не удалось построить маршрут. Проверьте сеть и выберите другой старт или финиш.';
}

String walkProposalUiError(Object error) {
  debugPrint('Smart Walk proposal failure: ${error.runtimeType}');
  if (error is SocketException ||
      (error is DioException &&
          error.type == DioExceptionType.connectionError)) {
    return 'Нет связи с сервером подбора прогулок. Проверьте сеть и адрес сервера, затем повторите попытку.';
  }
  if (error is TimeoutException ||
      (error is DioException &&
          (error.type == DioExceptionType.connectionTimeout ||
              error.type == DioExceptionType.sendTimeout ||
              error.type == DioExceptionType.receiveTimeout))) {
    return 'Сервер подбора прогулок не ответил вовремя. Попробуйте ещё раз.';
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null && status >= 500) {
      return 'Сервер подбора прогулок временно недоступен. Попробуйте позже.';
    }
    if (status == 400 || status == 422) {
      return 'Сервер не принял параметры прогулки. Проверьте старт и выбранный режим, затем повторите подбор.';
    }
  }
  if (error is FormatException ||
      error is TypeError ||
      (error is DioException &&
          (error.error is FormatException || error.error is TypeError))) {
    return 'Сервер вернул некорректный ответ подбора прогулки. Попробуйте ещё раз.';
  }
  return 'Не удалось подобрать маршрут. Попробуйте ещё раз.';
}

String searchUiError(Object error) {
  debugPrint('Search failure: ${error.runtimeType}');
  final message = error.toString().replaceFirst('Exception: ', '');
  const safeMessages = {
    'Время ожидания ответа от сервиса поиска истекло.',
    'Нет связи с сервером поиска. Проверьте сеть.',
    'Превышен лимит запросов поиска. Повторите попытку через минуту.',
    'Объект не найден на карте.',
    'Сервис поиска временно недоступен.',
    'Не удалось распознать адрес точки',
    'Некорректный формат ответа геокодера',
  };
  return safeMessages.contains(message)
      ? message
      : 'Не удалось найти адрес. Проверьте сеть и попробуйте ещё раз.';
}
