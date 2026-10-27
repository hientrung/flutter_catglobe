import 'package:catglobe_dev/src/cgscript.dart';
import 'package:test/test.dart';

void main() {
  test('returns result directly, including null', () {
    expect(parseCgScriptResponse('{"result":{"value":42},"error":null}', 200),
        {'value': 42});
    expect(parseCgScriptResponse('{"result":null,"error":null}', 200), isNull);
  });
  test('throws non-null error preserving its object', () {
    expect(
        () => parseCgScriptResponse(
            '{"result":42,"error":{"message":"Failed"}}', 200),
        throwsA(isA<CgScriptException>()
            .having((e) => e.error, 'error', {'message': 'Failed'})));
    expect(() => parseCgScriptResponse('{"result":null,"error":false}', 200),
        throwsA(isA<CgScriptException>()));
  });
  test('rejects HTTP failures and malformed envelopes', () {
    expect(() => parseCgScriptResponse('{"result":null,"error":null}', 401),
        throwsStateError);
    expect(() => parseCgScriptResponse('[]', 200), throwsFormatException);
    expect(() => parseCgScriptResponse('{"error":null}', 200),
        throwsFormatException);
  });
}
