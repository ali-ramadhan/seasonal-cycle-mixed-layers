# # Free convection

# This script runs a simulation of convection driven by cooling at the 
# surface of an idealized, stratified, rotating ocean surface boundary layer.

using LESbrary, Printf, Statistics

# Domain

using Oceananigans.Grids

grid = RegularCartesianGrid(size=(32, 32, 32), x=(0, 128), y=(0, 128), z=(-64, 0))

# Buoyancy and boundary conditions

using Oceananigans.Buoyancy, Oceananigans.BoundaryConditions

Qᵇ = 1e-7
N² = 1e-5

buoyancy = SeawaterBuoyancy(equation_of_state=LinearEquationOfState(α=2e-4), constant_salinity=35.0)

α = buoyancy.equation_of_state.α
g = buoyancy.gravitational_acceleration

## Compute temperature flux and gradient from buoyancy flux and gradient
Qᶿ = Qᵇ / (α * g)
dθdz = N² / (α * g)

θ_bcs = TracerBoundaryConditions(grid, top = BoundaryCondition(Flux, Qᶿ),
                                       bottom = BoundaryCondition(Gradient, dθdz))

# LES Model

# Wall-aware AMD model constant which is 'enhanced' near the upper boundary.
# Necessary to obtain a smooth temperature distribution.
using LESbrary.NearSurfaceTurbulenceModels: SurfaceEnhancedModelConstant

Cᴬᴹᴰ = SurfaceEnhancedModelConstant(grid.Δz, C₀ = 1/12, enhancement = 7, decay_scale = 4 * grid.Δz)

# Instantiate Oceananigans.IncompressibleModel

using Oceananigans

model = IncompressibleModel(architecture = CPU(),
                             timestepper = :RungeKutta3,
                                    grid = grid,
                                 tracers = :T,
                                buoyancy = buoyancy,
                                coriolis = FPlane(f=1e-4),
                                 closure = AnisotropicMinimumDissipation(C=Cᴬᴹᴰ),
                     boundary_conditions = (T=θ_bcs,))

# # Initial condition

Ξ(z) = rand() * exp(z / 8)

θᵢ(x, y, z) = dθdz * z + 1e-6 * Ξ(z) * dθdz * grid.Lz

set!(model, T=θᵢ)

# # Prepare the simulation

using Oceananigans.Utils: hour, minute
using LESbrary.Utils: SimulationProgressMessenger

# Adaptive time-stepping
wizard = TimeStepWizard(cfl=0.5, Δt=2.0, max_change=1.1, max_Δt=30.0)

simulation = Simulation(model, Δt=wizard, stop_time=8hour, iteration_interval=100, 
                        progress=SimulationProgressMessenger(model, wizard))

# Prepare Output

using Oceananigans.Utils: GiB
using Oceananigans.OutputWriters: JLD2OutputWriter

prefix = @sprintf("free_convection_Qb%.1e_Nsq%.1e_Nh%d_Nz%d", Qᵇ, N², grid.Nx, grid.Nz)

data_directory = joinpath(@__DIR__, "..", "data", prefix) # save data in /data/prefix

# Copy this file into the directory with data
mkpath(datmixing length calculationa_directory)
cp(@__FILE__, joinpath(data_directory, basename(@__FILE__)), force=true)

simulation.output_writers[:fields] = JLD2OutputWriter(model, merge(model.velocities, model.tracers); 
                                                      time_interval = 4hour, # every quarter period
                                                             prefix = prefix * "_fields",
                                                                dir = data_directory,
                                                       max_filesize = 2GiB,
                                                              force = true)
    
# Horizontally-averaged turbulence statistics
turbulence_statistics = LESbrary.TurbulenceStatistics.first_through_second_order(model)
tke_budget_statistics = LESbrary.TurbulenceStatistics.turbulent_kinetic_energy_budget(model)

simulation.output_writers[:statistics] =
    JLD2OutputWriter(model, merge(turbulence_statistics, tke_budget_statistics),
                     time_averaging_window = 15minute,
                             time_interval = 1hour,
                                    prefix = prefix * "_statistics",
                                       dir = data_directory,
                                     force = true)

# # Run

LESbrary.Utils.print_banner(simulation)

run!(simulation)

# # Load and plot turbulence statistics

using JLD2, Plots

## Some plot parameters
linewidth = 3
ylim = (-64, 0)
plot_size = (1000, 500)
zC = znodes(Cell, grid)
zF = znodes(Face, grid)

## Load data
file = jldopen(simulation.output_writers[:statistics].filepath)

iterations = parse.(Int, keys(file["timeseries/t"]))
iter = iterations[end] # plot final iteration

## Temperature
T = file["timeseries/T/$iter"][1, 1, :]

## Velocity variances
w²  = file["timeseries/ww/$iter"][1, 1, :]
tke = file["timeseries/turbulent_kinetic_energy/$iter"][1, 1, :]

## Terms in the TKE budget
      buoyancy_flux =   file["timeseries/buoyancy_flux/$iter"][1, 1, :]
   shear_production =   file["timeseries/shear_production/$iter"][1, 1, :]
        dissipation = - file["timeseries/dissipation/$iter"][1, 1, :]
 pressure_transport = - file["timeseries/pressure_transport/$iter"][1, 1, :]
advective_transport = - file["timeseries/advective_transport/$iter"][1, 1, :]

total_transport = pressure_transport .+ advective_transport

## For mixing length calculation
wT = file["timeseries/wT/$iter"][1, 1, 2:end-1]

close(file)

## Post-process the data to determine the mixing length

## Mixing length, computed at cell interfaces and omitting boundaries
Tz = @. (T[2:end] - T[1:end-1]) / grid.Δz
bz = @. α * g * Tz
tkeᶠ = @. (tke[1:end-1] + tke[2:end]) / 2

## Mixing length model: wT ∝ - ℓᵀ √tke ∂z T ⟹  ℓᵀ = wT / (√tke ∂z T)
ℓ_measured = @. - wT / (√(tkeᶠ) * Tz)
ℓ_estimated = @. min(-zF[2:end-1], sqrt(tkeᶠ / max(0, bz)))

# Plot data

temperature = plot(T, zC, size = plot_size,
                     linewidth = linewidth,
                        xlabel = "Temperature (ᵒC)",
                        ylabel = "z (m)",
                          ylim = ylim,
                         label = nothing)

variances = plot(tke, zC, size = plot_size,
                     linewidth = linewidth,
                        xlabel = "Velocity variances (m² s⁻²)",
                        ylabel = "z (m)",
                          ylim = ylim,
                         label = "(u² + v² + w²) / 2")

plot!(variances, 1/2 .* w², zF, linewidth = linewidth,
                                    label = "w² / 2")

budget = plot([buoyancy_flux dissipation total_transport], zC, size = plot_size,
              linewidth = linewidth,
                 xlabel = "TKE budget terms",
                 ylabel = "z (m)",
                   ylim = ylim,
                  label = ["buoyancy flux" "dissipation" "kinetic energy transport"])

mixing_length = plot([ℓ_measured ℓ_estimated], zF[2:end-1], size = plot_size,
                                                       linewidth = linewidth,
                                                          xlabel = "Mixing length (m)",
                                                          ylabel = "z (m)",
                                                            xlim = (-5, 20),
                                                            ylim = ylim,
                                                           label = ["measured" "estimated"])

plot(temperature, variances, budget, mixing_length, layout=(1, 4))
