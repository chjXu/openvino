// Copyright (C) 2020 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
//

#pragma once

#include <string>
#include <memory>
#include "ngraph_functions/low_precision_transformations/fake_quantize_function.hpp"
#include "functional_test_utils/low_precision_transformations/layer_transformation.hpp"

#include "ngraph_functions/low_precision_transformations/common/fake_quantize_on_data.hpp"
#include "ngraph_functions/low_precision_transformations/common/fake_quantize_on_weights.hpp"

namespace LayerTestsDefinitions {

class FakeQuantizePrecisionSelectionTransformationActualValues {
public:
    ngraph::builder::subgraph::FakeQuantizeOnData fakeQuantizeOnData;
    ngraph::builder::subgraph::FakeQuantizeOnWeights fakeQuantizeOnWeights;
};

inline std::ostream& operator<<(std::ostream& out, const FakeQuantizePrecisionSelectionTransformationActualValues& values) {
    return out << values.fakeQuantizeOnData << "_" << values.fakeQuantizeOnWeights;
}

class FakeQuantizePrecisionSelectionTransformationExpectedValues {
public:
    ngraph::element::Type fakeQuantizeOnDataOutPrecision;
    ngraph::builder::subgraph::FakeQuantizeOnData fakeQuantizeOnData;
    ngraph::builder::subgraph::FakeQuantizeOnWeights fakeQuantizeOnWeights;
};

inline std::ostream& operator<<(std::ostream& out, const FakeQuantizePrecisionSelectionTransformationExpectedValues& values) {
    return out << values.fakeQuantizeOnDataOutPrecision << "_" << values.fakeQuantizeOnData << "_" << values.fakeQuantizeOnWeights;
}

class FakeQuantizePrecisionSelectionTransformationTestValues {
public:
    std::vector<ngraph::element::Type> precisionsOnActivations;
    std::vector<ngraph::element::Type> precisionsOnActivationForLimitedOperation;
    bool operationBeforeLimitedOperationIsPrecisionTransparent;
    FakeQuantizePrecisionSelectionTransformationActualValues actual;
    FakeQuantizePrecisionSelectionTransformationExpectedValues expected;
};

inline std::ostream& operator<<(std::ostream& out, const FakeQuantizePrecisionSelectionTransformationTestValues& values) {
    return out << values.operationBeforeLimitedOperationIsPrecisionTransparent << "_" << values.actual << "_" << values.expected;
}

typedef std::tuple<
    InferenceEngine::Precision,
    InferenceEngine::SizeVector,
    std::string,
    ngraph::pass::low_precision::LayerTransformation::Params,
    FakeQuantizePrecisionSelectionTransformationTestValues> FakeQuantizeTransformationParams;

class FakeQuantizePrecisionSelectionTransformation :
    public testing::WithParamInterface<FakeQuantizeTransformationParams>,
    public LayerTestsUtils::LayerTransformation {
public:
    static std::string getTestCaseName(testing::TestParamInfo<FakeQuantizeTransformationParams> obj);

protected:
    void SetUp() override;
};

}  // namespace LayerTestsDefinitions
