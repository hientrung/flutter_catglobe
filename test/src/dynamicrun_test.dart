import 'package:catglobe_dev/src/dynamicrun.dart';
import 'package:test/test.dart';

void main() {
  test('returns result directly, including null', () {
    expect(parseDynamicRunResponse('{"result":{"value":42},"error":null}', 200),
        {'value': 42});
    expect(
        parseDynamicRunResponse('{"result":null,"error":null}', 200), isNull);
  });
  test('throws non-null error preserving its object', () {
    expect(
        () => parseDynamicRunResponse(
            '{"result":42,"error":{"message":"Failed"}}', 200),
        throwsA(isA<DynamicRunException>()
            .having((e) => e.error, 'error', {'message': 'Failed'})));
    expect(() => parseDynamicRunResponse('{"result":null,"error":false}', 200),
        throwsA(isA<DynamicRunException>()));
  });
  test('rejects HTTP failures and malformed envelopes', () {
    expect(() => parseDynamicRunResponse('{"result":null,"error":null}', 401),
        throwsStateError);
    expect(() => parseDynamicRunResponse('[]', 200), throwsFormatException);
    expect(() => parseDynamicRunResponse('{"error":null}', 200),
        throwsFormatException);
  });
}
