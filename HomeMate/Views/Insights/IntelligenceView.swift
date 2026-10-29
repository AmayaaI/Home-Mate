import SwiftUI
import Charts
import CoreML

struct AnalyticsView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: AnalyticsViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            AnalyticsViewScreen(viewModel: model)
        }.id(dependencies.household.identity)
    }
}

private struct AnalyticsViewScreen: View {



    @ObservedObject var viewModel: AnalyticsViewModel

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HomeSectionTitle(eyebrow: "A clearer picture", title: "Expense insights")
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("MONTHLY OVERVIEW", systemImage: "sparkle")
                                .font(.caption2.weight(.bold)).tracking(1.2)
                            Spacer()
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }.foregroundStyle(.white.opacity(0.84))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(viewModel.money(viewModel.currentTotal))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .tracking(-1).contentTransition(.numericText())
                                .minimumScaleFactor(0.6).lineLimit(1)
                            Text(Date.now.formatted(.dateTime.month(.wide).year()))
                                .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.72))
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.caption.weight(.bold)).foregroundStyle(DashboardPalette.mint)
                            Text("Last month")
                                .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.72))
                            Spacer()
                            Text(viewModel.money(viewModel.previous))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .padding(22)
                    .foregroundStyle(.white)
                    .background {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(LinearGradient(colors: [DashboardPalette.brandFill, DashboardPalette.brandFill.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Circle().stroke(.white.opacity(0.09), lineWidth: 1).frame(width: 190, height: 190).offset(x: 65, y: -90)
                            Circle().fill(.white.opacity(0.06)).frame(width: 125, height: 125).offset(x: 32, y: -54)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: DashboardPalette.brandFill.opacity(0.22), radius: 18, y: 9)
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Where it goes", systemImage: "chart.pie.fill")
                            .font(.headline.weight(.bold)).foregroundStyle(DashboardPalette.green)
                        if viewModel.groups.isEmpty {
                            ContentUnavailableView("Your story starts here", systemImage: "chart.bar", description: Text("Record expenses to see your spending patterns."))
                        } else {
                            Chart(viewModel.groups, id: \.0) { item in
                                BarMark(x: .value("Amount", item.1), y: .value("Category", item.0)).cornerRadius(6).foregroundStyle(DashboardPalette.green.gradient)
                            }.chartXAxis(.hidden).chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }.frame(height: CGFloat(max(2, viewModel.groups.count)) * 38)
                            ForEach(viewModel.groups, id: \.0) { item in
                                HStack(spacing: 10) {
                                    Circle().fill(DashboardPalette.green).frame(width: 7, height: 7)
                                    Text(item.0).font(.footnote)
                                    Spacer()
                                    Text(viewModel.money(item.1)).font(.subheadline .weight(.semibold))
                                }.padding(12).background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.padding(20).homeCard(cornerRadius: 22)
                    anomalyCard
                    patternsCard
                    if let warning = viewModel.budgetWarning {
                        Label(warning, systemImage: "exclamationmark.circle").font(.subheadline)
                            .padding(20).homeCard(cornerRadius: 22).accessibilityElement(children: .combine)
                    }
                    forecastCard
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Calculated spending summary").font(.headline .weight(.bold)).foregroundStyle(DashboardPalette.green)
                        if let largest = viewModel.groups.max(by: { $0.1 < $1.1 }) { Text("\(largest.0) is your largest category this month.").font(.body .weight(.medium)) }
                        if viewModel.previous > 0 {
                            let current = viewModel.currentTotal
                            Text("Month-to-date spending is \(Int(abs(current - viewModel.previous) / viewModel.previous * 100))% \(current >= viewModel.previous ? "higher" : "lower") than last month's total.").font(.footnote).foregroundStyle(DashboardPalette.muted)
                            HStack { Text("Average of these two totals"); Spacer(); Text(viewModel.money((current + viewModel.previous) / 2)).fontWeight(.semibold) }.font(.footnote).padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        } else { Text("Add expenses across multiple months to unlock comparisons and estimates.").font(.footnote).foregroundStyle(DashboardPalette.muted) }
                        ForEach(viewModel.alerts) { alert in
                            Label("\(alert.category) spending has already exceeded its three-month average by more than the alert threshold.", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(DashboardPalette.green)
                        }
                        Text("Spending alerts compare this month's total with three prior monthly totals. They use statistical thresholds, not a separate ML model.").font(.caption2).foregroundStyle(DashboardPalette.muted)
                        Text("Based on recorded expenses and simple historical averages.").font(.caption2).foregroundStyle(DashboardPalette.muted)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DashboardPalette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DashboardPalette.green.opacity(0.10), lineWidth: 1))
                }.padding(24).padding(.bottom, 16).frame(maxWidth: 860).frame(maxWidth: .infinity)
            }.task(id: viewModel.analysisKey) { await viewModel.analyse() }
                .background(HomeBackdrop()).navigationTitle("Insights").navigationBarTitleDisplayMode(.inline)
    }
    private var anomalyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Unusual transactions", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(DashboardPalette.green)
            Text(viewModel.context?.family?.name ?? "Private household").font(.subheadline)
            Text("Last 30 days · experimental Core ML model trained on simulated households. Scores are not calibrated confidence or proof of an error.").font(.caption).foregroundStyle(.secondary)
            if let report = viewModel.analysis?.anomalies {
                if report.unavailable || report.fallbackCount > 0 {
                    Label("Statistical fallback: the ML model was unavailable or could not score some transactions.", systemImage: "exclamationmark.triangle").font(.caption)
                }
                if report.failed > 0 {
                    Text("Some records could not be analysed. Check their amounts and categories.").font(.caption)
                }
                if report.recentCount == 0 {
                    Text("No recorded payments in the last 30 days to analyse.").font(.subheadline).foregroundStyle(.secondary)
                }
                if report.insufficient > 0 {
                    Text("Not enough history for \(report.insufficient) recent transactions. Each needs 20 earlier payments, including 6 in its category, across at least 30 days within the previous 180 days.").font(.caption).foregroundStyle(.secondary)
                }
                if report.transactions.isEmpty && report.evaluated > 0 {
                    Text("No unusual transactions flagged among \(report.evaluated) eligible payments. This does not guarantee every payment is typical.").font(.subheadline)
                }
                ForEach(report.transactions) { item in
                    NavigationLink { RecordDetailView(record: item.record, presentsAsSheet: false) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.record.title).font(.headline)
                            Text(viewModel.money(item.record.amount)).font(.subheadline.weight(.semibold))
                            Text(item.isML ? "Core ML flag" : "Statistical fallback flag").font(.caption.weight(.semibold))
                            Text(item.explanation).font(.caption).foregroundStyle(.secondary)
                            Text("Prior category average: \(viewModel.money(item.baseline)). Review whether this was a planned purchase or a duplicate before changing your budget.").font(.caption).foregroundStyle(.secondary)
                            Text("Comparison explains the observed difference, not the model’s internal reasoning.").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(DashboardPalette.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityElement(children: .combine)
                }
            } else { ProgressView("Checking spending patterns…") }
        }.padding(20).homeCard(cornerRadius: 22)
    }
    private var patternsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Spending patterns · calculated", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
            if let patterns = viewModel.analysis?.patterns {
                if patterns.isEmpty {
                    Text("Add records across completed months to see category changes and possible recurring costs.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(patterns) { pattern in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pattern.title).font(.subheadline.weight(.semibold))
                        Text(pattern.detail).font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
            } else { ProgressView("Finding patterns…") }
        }.padding(20).homeCard(cornerRadius: 22)
    }
    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Core ML predictions", systemImage: "chart.line.uptrend.xyaxis").font(.headline .weight(.bold))
                Spacer()
                Text("DEMO TRAINED").font(.caption2.weight(.bold)).padding(6).background(DashboardPalette.mint.opacity(0.25), in: Capsule())
            }.foregroundStyle(DashboardPalette.green)
            Label(viewModel.categoryModelReady ? "Expense classifier loaded" : "Expense classifier unavailable", systemImage: viewModel.categoryModelReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption .weight(.medium))
            if viewModel.analysis == nil {
                ProgressView("Analysing household spending…")
            } else {
            switch viewModel.forecast {
            case .success(let forecast):
                VStack(spacing: 12) {
                    forecastRow(forecast.thisMonth, amount: forecast.thisMonthAmount,
                                caption: forecast.thisMonthUsesTrendFallback ? "Trend-based estimate" : "Estimated full month")
                    Text("Recorded this month: \(viewModel.money(viewModel.currentTotal))").font(.subheadline)
                    if viewModel.preferences.monthlyBudget > 0 {
                        Text("Monthly budget: \(viewModel.money(viewModel.preferences.monthlyBudget))").font(.subheadline)
                    } else { Text("No budget available for this household.").font(.caption).foregroundStyle(.secondary) }
                    if forecast.thisMonthAmount < viewModel.currentTotal {
                        Text("Actual spending has already exceeded this estimate. Use recorded spending when planning the rest of this month.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    forecastRow(forecast.nextMonth, amount: forecast.nextMonthAmount,
                                caption: forecast.nextMonthUsesTrendFallback ? "Trend-based estimate" : "Two-step model estimate")
                }
                if forecast.thisMonthUsesTrendFallback || forecast.nextMonthUsesTrendFallback {
                    Text("This spending pattern is outside the model’s demo training range. A damped trend from recent months is used instead of an unreliable model extrapolation.")
                        .font(.caption).foregroundStyle(DashboardPalette.muted)
                } else {
                    Text("Based on your last three completed months. Next month's prediction also uses this month's estimate, so uncertainty increases with the extra step.")
                        .font(.caption2).foregroundStyle(DashboardPalette.muted)
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.footnote).foregroundStyle(DashboardPalette.muted)
            }
            }
            Text("No calibrated confidence interval is available. Missing records, one-off purchases and changing habits can reduce accuracy. The second month is less certain.")
                .font(.caption).foregroundStyle(.secondary)
            if let comparisons = viewModel.analysis?.comparisons, !comparisons.isEmpty {
                Text("Historical replay · estimate versus actual").font(.subheadline.weight(.semibold))
                ForEach(comparisons) { comparison in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comparison.month.formatted(.dateTime.month(.wide).year())).font(.subheadline)
                        Text("Estimate \(viewModel.money(comparison.estimate)) · Actual \(viewModel.money(comparison.actual))")
                        Text("Absolute error: \(comparison.percentageError.formatted(.number.precision(.fractionLength(1))))%")
                        Text("Historical-mean baseline: \(viewModel.money(comparison.baseline)) · Error: \(viewModel.money(abs(comparison.baseline - comparison.actual)))")
                    }.font(.caption).accessibilityElement(children: .combine)
                }
                Text("Recomputed using only months before each target month; these were not saved predictions. This is a household history check, not independent model validation.").font(.caption).foregroundStyle(.secondary)
            } else if viewModel.analysis != nil {
                Text("Forecast comparison needs four consecutive completed months with spending.").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink { CoreMLDemoView() } label: {
                Label("Try the trained models", systemImage: "play.circle.fill").font(.footnote .weight(.semibold))
            }
            Text("Real on-device Core ML models trained on demonstration data: authored English expense descriptions and simulated spending histories. Predictions are experimental; review categories and estimates.").font(.caption2).foregroundStyle(DashboardPalette.muted)
        }.padding(20).homeCard(cornerRadius: 22)
    }
    private func forecastRow(_ month: Date, amount: Double, caption: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(month.formatted(.dateTime.month(.wide).year())).font(.subheadline .weight(.semibold)); Text(caption).font(.caption2).foregroundStyle(DashboardPalette.muted) }
            Spacer()
            Text(viewModel.money(amount)).font(.headline .weight(.bold)).foregroundStyle(DashboardPalette.green)
        }
    }

}


struct CoreMLDemoView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: MLDemoViewModel(store: dependencies.store, account: dependencies.account)) { model in
            CoreMLDemoViewScreen(viewModel: model)
        }.id(dependencies.household.identity)
    }
}

private struct CoreMLDemoViewScreen: View {








    @ObservedObject var viewModel: MLDemoViewModel
    private var description: String { get { viewModel.description } nonmutating set { viewModel.description = newValue } }
    private var oldest: Double { get { viewModel.oldest } nonmutating set { viewModel.oldest = newValue } }
    private var previous: Double { get { viewModel.previous } nonmutating set { viewModel.previous = newValue } }
    private var latest: Double { get { viewModel.latest } nonmutating set { viewModel.latest = newValue } }
    private var category: String? { get { viewModel.category } nonmutating set { viewModel.category = newValue } }
    private var prediction: Double? { get { viewModel.prediction } nonmutating set { viewModel.prediction = newValue } }
    private var categoryError: String? { get { viewModel.categoryError } nonmutating set { viewModel.categoryError = newValue } }
    private var forecastError: String? { get { viewModel.forecastError } nonmutating set { viewModel.forecastError = newValue } }
    var body: some View {
        Form {
            Section {
                Label("Actual on-device inference", systemImage: "cpu").font(.headline)
                Text("These are editable demo inputs. This screen does not change your household records. Both models were trained on demonstration data, not your personal expenses.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Expense category") {
                TextField("Expense description", text: $viewModel.description, axis: .vertical)
                Button("Predict category") { viewModel.predictCategory() }
                if let category { LabeledContent("Core ML result", value: category) }
                if let categoryError { Text(categoryError).font(.caption).foregroundStyle(.red) }
            }
            Section("Following month's estimate") {
                TextField("Three months ago", value: $viewModel.oldest, format: .number).keyboardType(.decimalPad)
                TextField("Two months ago", value: $viewModel.previous, format: .number).keyboardType(.decimalPad)
                TextField("Last month", value: $viewModel.latest, format: .number).keyboardType(.decimalPad)
                Button("Run forecast model", systemImage: "chart.line.uptrend.xyaxis") { viewModel.predictForecast() }
                if let prediction {
                    LabeledContent(viewModel.forecastUsesTrendFallback ? "Trend-based estimate" : "Core ML estimate", value: viewModel.money(prediction))
                    if viewModel.forecastUsesTrendFallback {
                        Text("These ratios are outside the model’s demo training range, so a damped trend from recent months is used.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let forecastError { Text(forecastError).font(.caption).foregroundStyle(.red) }
                Text("The model learns spending trends from simulated histories. Demo estimates are not validated for real-world forecasting.").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(HomeBackdrop()).navigationTitle("Try Core ML").navigationBarTitleDisplayMode(.inline)
    }
}

/// Reuses the same household-scoped analysis in Expenses and on Home.
struct ExpenseAnalysisSummary: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var body: some View {
        ViewModelHost(make: AnalyticsViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            ExpenseAnalysisSummaryContent(viewModel: model)
        }.id(dependencies.household.identity)
    }
}
private struct ExpenseAnalysisSummaryContent: View {
    @ObservedObject var viewModel: AnalyticsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = viewModel.analysis?.anomalies {
                Text(report.transactions.isEmpty ? "Review your spending insights" : "\(report.transactions.count) payments to review")
                    .font(.subheadline.weight(.semibold))
                Text(report.fallbackCount > 0 || report.unavailable ? "Statistical fallback · see Insights for details" : "On-device Core ML · experimental unusual-spending analysis")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = viewModel.budgetWarning { Text(warning).font(.caption) }
            } else { ProgressView("Analysing spending…").font(.caption) }
            NavigationLink { AnalyticsView() } label: {
                Label("Spending insights", systemImage: "chart.line.uptrend.xyaxis").font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: viewModel.analysisKey) { await viewModel.analyse() }
    }
}
