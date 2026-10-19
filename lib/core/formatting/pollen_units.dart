import 'package:smart_navigator_spb/core/constants/api_constants.dart';

/// The source unit remains `grains/m³` in the model and in technical details.
/// Human-facing pollen lines use a Russian label instead of hiding the model
/// quantity or changing the value.
const String pollenConcentrationDisplayUnit = 'зёрен пыльцы/м³';

String pollenUnitForDisplay(String unit) =>
    unit == ApiConstants.pollenConcentrationUnit
    ? pollenConcentrationDisplayUnit
    : unit;
