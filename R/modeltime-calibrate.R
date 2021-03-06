# MODELTIME CALIBRATE ----

#' Preparation for forecasting
#'
#' Calibration sets the stage for accuracy and forecast confidence
#' by computing predictions and residuals from out of sample data.
#'
#' @param object A fitted model object that is either:
#' 1. A modeltime table that has been created using [modeltime_table()]
#' 2. A workflow that has been fit by [fit.workflow()] or
#' 3. A parsnip model that has been fit using [fit.model_spec()]
#' @param new_data A test data set `tibble` containing future information (timestamps and actual values).
#' @param quiet Hide errors (`TRUE`, the default), or display them as they occur?
#' @param ... Additional arguments passed to [modeltime_forecast()].
#'
#'
#' @return A Modeltime Table (`mdl_time_tbl`) with nested `.calibration_data` added
#'
#' @details
#'
#' The results of calibration are used for:
#' - __Forecast Confidence Interval Estimation__: The out of sample residual data is used to calculate the
#'   confidence interval. Refer to [modeltime_forecast()].
#' - __Accuracy Calculations:__ The out of sample actual and prediction values are used to calculate
#'   performance metrics. Refer to [modeltime_accuracy()]
#'
#' The calibration steps include:
#'
#' 1. If not a Modeltime Table, objects are converted to Modeltime Tables internally
#' 2. Two Columns are added:
#'   - `.type`: Indicates the sample type. Only "Test" is currently available.
#'   - `.calibration_data`: Contains a tibble with Timestamps, Actual Values, Predictions and Residuals
#'    calculated from `new_data` (Test Data)
#'
#'
#' @examples
#' library(tidyverse)
#' library(lubridate)
#' library(timetk)
#' library(parsnip)
#' library(rsample)
#'
#' # Data
#' m750 <- m4_monthly %>% filter(id == "M750")
#'
#' # Split Data 80/20
#' splits <- initial_time_split(m750, prop = 0.9)
#'
#' # --- MODELS ---
#'
#' # Model 1: auto_arima ----
#' model_fit_arima <- arima_reg() %>%
#'     set_engine(engine = "auto_arima") %>%
#'     fit(value ~ date, data = training(splits))
#'
#'
#' # ---- MODELTIME TABLE ----
#'
#' models_tbl <- modeltime_table(
#'     model_fit_arima
#' )
#'
#' # ---- CALIBRATE ----
#'
#' calibration_tbl <- models_tbl %>%
#'     modeltime_calibrate(new_data = testing(splits))
#'
#' # ---- ACCURACY ----
#'
#' calibration_tbl %>%
#'     modeltime_accuracy()
#'
#' # ---- FORECAST ----
#'
#' calibration_tbl %>%
#'     modeltime_forecast(
#'         new_data    = testing(splits),
#'         actual_data = m750
#'     )
#'
#'
#' @name modeltime_calibrate
NULL

#' @export
#' @rdname modeltime_calibrate
modeltime_calibrate <- function(object, new_data,
                                quiet = TRUE, ...) {

    # Checks
    if (rlang::is_missing(new_data)) {
        glubort("Missing 'new_data'. Try adding a test data set using rsample::testing(splits). See help for more info: ?modeltime_calibrate ")
    }

    UseMethod("modeltime_calibrate")
}

#' @export
modeltime_calibrate.default <- function(object, new_data,
                                        quiet = TRUE, ...) {
    glubort("Received an object of class: {class(object)[1]}. Expected an object of class:\n 1. 'workflow' - That has been fitted (trained).\n 2. 'model_fit' - A fitted parsnip model.\n 3. 'mdl_time_tbl' - A Model Time Table made with 'modeltime_table()'.")
}

#' @export
modeltime_calibrate.mdl_time_tbl <- function(object, new_data,
                                             quiet = TRUE, ...) {
    data <- object

    # If object has already been calibrated, remove calibration
    if (is_calibrated(data)) {
        data <- data %>%
            dplyr::select(-.type, -.calibration_data)
    }

    safe_calc_residuals <- purrr::safely(calc_residuals,
                                         otherwise = NA, # Need NA here for plotting correctly
                                         quiet = quiet)

    ret <- data %>%
        dplyr::ungroup() %>%
        dplyr::mutate(.nested.col = purrr::map2(
            .x         = .model,
            .y         = .model_id,
            .f         = function(obj, idx) {

                ret <- safe_calc_residuals(
                    obj,
                    test_data = new_data
                )
                ret <- ret %>% purrr::pluck("result")

                return(ret)
            })
        ) %>%
        # dplyr::select(-.model) %>%
        tidyr::unnest(cols = .nested.col)

    # Stop when errors are Fatal (all calibrations fail)
    # - Example: New levels in the testing(splits) are present
    validate_modeltime_calibration(ret)

    # Remove .nested_col - happens some model fail, but not all models
    if (".nested.col" %in% names(ret)) {
        ret <- ret %>%
            dplyr::select(-.nested.col)
    }

    # Handle NULL .calibration_data - happens when NA values are present
    ret <- ret %>%
        dplyr::mutate(.is_null = purrr::map_lgl(.calibration_data, is.null)) %>%
        dplyr::mutate(.calibration_data = ifelse(.is_null, list(NA), .calibration_data)) %>%
        dplyr::select(-.is_null)

    # Alert Failures
    if (!quiet) {
        alert_modeltime_calibration(ret)
    } else {
        check_bad_type_tbl <- check_type_not_missing(ret) %>%
            dplyr::filter(fail_check)
        if (nrow(check_bad_type_tbl) > 0) rlang::warn("Some models failed during calibration. Re-run with `modeltime_calibrate(quiet = FALSE)` to find the exact cause.")
    }

    if (!"mdl_time_tbl" %in% class(ret)) {
        class(ret) <- c("mdl_time_tbl", class(ret))
    }

    return(ret)
}

#' @export
modeltime_calibrate.model_spec <- function(object, new_data,
                                           quiet = TRUE, ...) {
    rlang::abort("Model spec must be trained using the 'fit()' function.")
}

#' @export
modeltime_calibrate.model_fit <- function(object, new_data,
                                          quiet = TRUE, ...) {

    ret <- modeltime_table(object) %>%
        modeltime_calibrate(new_data = new_data, quiet = quiet, ...)

    message("Converting to Modeltime Table.")

    return(ret)

}

#' @export
modeltime_calibrate.workflow <- function(object, new_data,
                                         quiet = TRUE, ...) {

    # Checks
    if (!object$trained) {
        rlang::abort("Workflow must be trained using the 'fit()' function.")
    }

    ret <- modeltime_table(object) %>%
        modeltime_calibrate(new_data = new_data, quiet = quiet, ...)

    message("Converting to Modeltime Table.")

    return(ret)

}



# UTILITIES ----

mdl_time_forecast_to_residuals <- function(forecast_data, test_data, idx_var_text) {

    predictions_tbl <- forecast_data %>%
        tidyr::pivot_wider(names_from = .key, values_from = .value) %>%
        tidyr::drop_na()

    # Return Residuals
    tibble::tibble(
        !!idx_var_text   := test_data %>% timetk::tk_index(),
        .actual           = predictions_tbl$actual,
        .prediction       = predictions_tbl$prediction,
        .residuals        = predictions_tbl$actual - predictions_tbl$prediction
    )

}

mdl_time_residuals_to_calibration <- function(residuals_data, .type = "Test") {

    # Return nested calibration tbl
    tibble::tibble(
        .type = .type,
        .calibration_data = list(residuals_data)
    )

}

calc_residuals <- function(object, test_data = NULL, ...) {

    model_fit <- object

    # Training Metrics
    train_metrics_tbl <- tibble::tibble()

    # Testing Metrics
    test_metrics_tbl <- tibble::tibble()

    # CALIBRATION -----
    if (!is.null(test_data)) {

        idx_var_text <- timetk::tk_get_timeseries_variables(test_data)[1]

        # print(is_modeltime_model(object))
        if (is_modeltime_model(object)) {
            # Is Modeltime Object

            residual_tbl <- pull_modeltime_residuals(object) %>%
                dplyr::rename(.prediction = .fitted)

            idx_resid <- timetk::tk_index(residual_tbl)
            idx_test  <- timetk::tk_index(test_data)

            # print(identical(idx_resid, idx_test))
            if (all(idx_test %in% idx_resid)) {
                # Can use Stored Residuals
                test_metrics_tbl <- residual_tbl %>%
                    dplyr::filter(!! sym(idx_var_text) %in% idx_test) %>%
                    mdl_time_residuals_to_calibration(.type = "Fitted")
            } else {
                # Cannot use Stored Residuals
                test_metrics_tbl <- object %>%
                    mdl_time_forecast(
                        new_data      = test_data,
                        actual_data   = test_data,
                        conf_interval = NULL,
                        ...
                    ) %>%
                    mdl_time_forecast_to_residuals(
                        test_data    = test_data,
                        idx_var_text = idx_var_text
                    ) %>%
                    mdl_time_residuals_to_calibration(.type = "Test")
            }
        } else {
            # Not modeltime object
            test_metrics_tbl <- object %>%
                mdl_time_forecast(
                    new_data      = test_data,
                    actual_data   = test_data,
                    # conf_interval = NULL,
                    ...
                ) %>%
                mdl_time_forecast_to_residuals(
                    test_data    = test_data,
                    idx_var_text = idx_var_text
                ) %>%
                mdl_time_residuals_to_calibration(.type = "Test")
        }

    }

    # print(test_metrics_tbl)

    metrics_tbl <- dplyr::bind_rows(train_metrics_tbl, test_metrics_tbl)

    return(metrics_tbl)
}


