# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require "#{File.dirname(__FILE__)}/resources/constants"
require "#{File.dirname(__FILE__)}/resources/weather"
require "#{File.dirname(__FILE__)}/resources/hvac"
require "#{File.dirname(__FILE__)}/resources/geometry"

# start the measure
class ResidentialPhotovoltaicsSAM < OpenStudio::Ruleset::ModelUserScript

  class PVSystem
    def initialize
    end
    attr_accessor(:size, :module_type, :inv_eff, :losses)   
  end
  
  class PVAzimuth
    def initialize
    end
    attr_accessor(:abs)
  end

  class PVTilt
    def initialize   
    end
    attr_accessor(:abs)
  end

  # human readable name
  def name
    return "Set Residential Photovoltaics SAM"
  end

  # human readable description
  def description
    return "Adds (or replaces) residential photovoltaics with the specified efficiency, size, orientation, and tilt. For both single-family detached and multifamily buildings, one panel is added (or replaced)."
  end

  # human readable description of modeling approach
  def modeler_description
    return "Any photovoltaic panels, generators, inverters, and electric load center distribution objects are removed. A photovoltaic panel, along with generator and inverter are added to the electric load center distribution object."
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new

    #make a double argument for size
    size = OpenStudio::Ruleset::OSArgument::makeDoubleArgument("size", false)
    size.setDisplayName("Size")
    size.setUnits("kW")
    size.setDescription("Size (power) per unit of the photovoltaic array in kW DC.")
    size.setDefaultValue(2.5)
    args << size
    
    #make a choice arguments for module type
    module_types_names = OpenStudio::StringVector.new
    module_types_names << Constants.PVModuleTypeStandard
    module_types_names << Constants.PVModuleTypePremium
    module_types_names << Constants.PVModuleTypeThinFilm
    module_type = OpenStudio::Ruleset::OSArgument::makeChoiceArgument("module_type", module_types_names, true)
    module_type.setDisplayName("Module Type")
    module_type.setDescription("Type of module to use for the PV simulation.")
    module_type.setDefaultValue(Constants.PVModuleTypeStandard)
    args << module_type

    #make a double argument for system losses
    system_losses = OpenStudio::Ruleset::OSArgument::makeDoubleArgument("system_losses", false)
    system_losses.setDisplayName("System Losses")
    system_losses.setUnits("frac")
    system_losses.setDescription("Difference between theoretical module-level and actual PV system performance due to wiring resistance losses, dust, module mismatch, etc.")
    system_losses.setDefaultValue(0.14)
    args << system_losses
    
    #make a double argument for inverter efficiency
    inverter_efficiency = OpenStudio::Ruleset::OSArgument::makeDoubleArgument("inverter_efficiency", false)
    inverter_efficiency.setDisplayName("Inverter Efficiency")
    inverter_efficiency.setUnits("frac")
    inverter_efficiency.setDescription("The efficiency of the inverter.")
    inverter_efficiency.setDefaultValue(0.96)
    args << inverter_efficiency
    
    #make a choice arguments for azimuth type
    azimuth_types_names = OpenStudio::StringVector.new
    azimuth_types_names << Constants.CoordRelative
    azimuth_types_names << Constants.CoordAbsolute
    azimuth_type = OpenStudio::Ruleset::OSArgument::makeChoiceArgument("azimuth_type", azimuth_types_names, true)
    azimuth_type.setDisplayName("Azimuth Type")
    azimuth_type.setDescription("Relative azimuth angle is measured clockwise from the front of the house. Absolute azimuth angle is measured clockwise from due south.")
    azimuth_type.setDefaultValue(Constants.CoordRelative)
    args << azimuth_type    
    
    #make a double argument for azimuth
    azimuth = OpenStudio::Ruleset::OSArgument::makeDoubleArgument("azimuth", false)
    azimuth.setDisplayName("Azimuth")
    azimuth.setUnits("degrees")
    azimuth.setDescription("The azimuth angle is measured clockwise.")
    azimuth.setDefaultValue(0)
    args << azimuth
    
    #make a choice arguments for tilt type
    tilt_types_names = OpenStudio::StringVector.new
    tilt_types_names << Constants.TiltPitch
    tilt_types_names << Constants.CoordAbsolute
    tilt_types_names << Constants.TiltLatitude
    tilt_type = OpenStudio::Ruleset::OSArgument::makeChoiceArgument("tilt_type", tilt_types_names, true)
    tilt_type.setDisplayName("Tilt Type")
    tilt_type.setDescription("Type of tilt angle referenced.")
    tilt_type.setDefaultValue(Constants.TiltPitch)
    args << tilt_type      
    
    #make a double argument for tilt
    tilt = OpenStudio::Ruleset::OSArgument::makeDoubleArgument("tilt", false)
    tilt.setDisplayName("Tilt")
    tilt.setUnits("degrees")
    tilt.setDescription("Angle of the tilt.")
    tilt.setDefaultValue(0)
    args << tilt
    
    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    if !File.directory? "#{File.dirname(__FILE__)}/resources/sam-sdk-2017-1-17"
      unzip_file = OpenStudio::UnzipFile.new("#{File.dirname(__FILE__)}/resources/sam-sdk-2017-1-17.zip")
      unzip_file.extractAllFiles(OpenStudio::toPath("#{File.dirname(__FILE__)}/resources"))
    end
    
    if !File.directory? "#{File.dirname(__FILE__)}/resources/ffi-1.9.17-x64-mingw32"
      unzip_file = OpenStudio::UnzipFile.new("#{File.dirname(__FILE__)}/resources/ffi-1.9.17-x64-mingw32.zip")
      unzip_file.extractAllFiles(OpenStudio::toPath("#{File.dirname(__FILE__)}/resources"))
    end
    $:.unshift "#{File.dirname(__FILE__)}/resources/ffi-1.9.17-x64-mingw32/lib" # TODO: since ffi is not packaged with openstudio
    require "#{File.dirname(__FILE__)}/resources/ssc_api"
    
    size = runner.getDoubleArgumentValue("size",user_arguments)
    module_type = runner.getStringArgumentValue("module_type",user_arguments)
    system_losses = runner.getDoubleArgumentValue("system_losses",user_arguments)
    inverter_efficiency = runner.getDoubleArgumentValue("inverter_efficiency",user_arguments)
    azimuth_type = runner.getStringArgumentValue("azimuth_type",user_arguments)
    azimuth = runner.getDoubleArgumentValue("azimuth",user_arguments)
    tilt_type = runner.getStringArgumentValue("tilt_type",user_arguments)
    tilt = runner.getDoubleArgumentValue("tilt",user_arguments)
        
    if azimuth > 360 or azimuth < 0
      runner.registerError("Invalid azimuth entered.")
      return false
    end	    
    
    pv_system = PVSystem.new
    pv_azimuth = PVAzimuth.new
    pv_tilt = PVTilt.new
    
    @weather = WeatherProcess.new(model, runner, File.dirname(__FILE__), header_only=true)
    if @weather.error?
      return false
    end
    
    obj_name = Constants.ObjectNamePhotovoltaics
    
    highest_roof_pitch = Geometry.get_roof_pitch(model.getSurfaces)
    
    pv_system.size = size
    pv_system.module_type = {Constants.PVModuleTypeStandard=>0, Constants.PVModuleTypePremium=>1, Constants.PVModuleTypeThinFilm=>2}[module_type]
    pv_system.inv_eff = inverter_efficiency * 100.0
    pv_system.losses = system_losses * 100.0
    pv_azimuth.abs = get_abs_azimuth(azimuth_type, azimuth, model.getBuilding.northAxis)
    pv_tilt.abs = get_abs_tilt(tilt_type, tilt, highest_roof_pitch, @weather.header.Latitude)
        
    p_data = SscApi.create_data_object
    SscApi.set_number(p_data, 'system_capacity', pv_system.size)
    SscApi.set_number(p_data, 'module_type', pv_system.module_type)
    SscApi.set_number(p_data, 'array_type', 0)
    SscApi.set_number(p_data, 'inv_eff', pv_system.inv_eff)
    SscApi.set_number(p_data, 'losses', pv_system.losses)
    SscApi.set_number(p_data, 'azimuth', pv_azimuth.abs)
    SscApi.set_number(p_data, 'tilt', pv_tilt.abs)    
    SscApi.set_number(p_data, 'adjust:constant', 0)
    SscApi.set_string(p_data, 'solar_resource_file', @weather.epw_path)
    p_mod = SscApi.create_module("pvwattsv5")
    SscApi.set_print(false)
    SscApi.execute_module(p_mod, p_data)
      
    obj_name = Constants.ObjectNamePhotovoltaics
      
    vertices = OpenStudio::Point3dVector.new
    vertices << OpenStudio::Point3d.new(0, 0, 0)
    vertices << OpenStudio::Point3d.new(0, 1, 0)
    vertices << OpenStudio::Point3d.new(1, 1, 0)
    vertices << OpenStudio::Point3d.new(1, 0, 0)
      
    # Remove existing photovoltaics
    model.getElectricLoadCenterDistributions.each do |electric_load_center_dist|
      next unless electric_load_center_dist.name.to_s == obj_name + " elec load center dist"
      electric_load_center_dist.generators.each do |generator|
        panel = generator.to_GeneratorPhotovoltaic.get
        panel.surface.get.to_ShadingSurface.get.shadingSurfaceGroup.get.remove
        panel.remove
      end
      electric_load_center_dist.trackScheduleSchemeSchedule.get.remove
      electric_load_center_dist.remove
    end      
      
    shading_surface_group = OpenStudio::Model::ShadingSurfaceGroup.new(model)
    shading_surface_group.setName(obj_name + " panel")
    shading_surface = OpenStudio::Model::ShadingSurface.new(vertices, model)
    shading_surface.setName(obj_name + " panel")
    shading_surface.setShadingSurfaceGroup(shading_surface_group)
      
    runner.registerInfo("#{(SscApi.get_array(p_data, "ac").inject(0){ |sum, x| sum + x }).round(2)} W-h")
    values = OpenStudio::Vector.new(8760)
    SscApi.get_array(p_data, "ac").each_with_index do |wh, i|
      values[i] = wh.to_f
    end
    start_date = model.getYearDescription.makeDate(1, 1)
    time_step = OpenStudio::Time.new(0, 0, 60, 0)
    timeseries = OpenStudio::TimeSeries.new(start_date, time_step, values, "W")
    schedule = OpenStudio::Model::ScheduleInterval.fromTimeSeries(timeseries, model).get
    schedule.setName(obj_name + " watt-hours")
      
    electric_load_center_dist = OpenStudio::Model::ElectricLoadCenterDistribution.new(model)
    electric_load_center_dist.setName(obj_name + " elec load center dist")
    electric_load_center_dist.setGeneratorOperationSchemeType("TrackSchedule")
    electric_load_center_dist.setTrackScheduleSchemeSchedule(schedule)
    electric_load_center_dist.setElectricalBussType("AlternatingCurrent")
      
    panel = OpenStudio::Model::GeneratorPhotovoltaic::simple(model)
    panel.setName(obj_name + " system")
    panel.setSurface(shading_surface)
    panel.setHeatTransferIntegrationMode("Decoupled")

    performance = panel.photovoltaicPerformance.to_PhotovoltaicPerformanceSimple.get
    performance.setName(obj_name + " module")
    performance.setFractionOfSurfaceAreaWithActiveSolarCells(1)
    performance.setFixedEfficiency(1)
          
    electric_load_center_dist.addGenerator(panel)
      
    return true

  end
  
  def get_abs_azimuth(azimuth_type, relative_azimuth, building_orientation)
    azimuth = nil
    if azimuth_type == Constants.CoordRelative
      azimuth = relative_azimuth + building_orientation
    elsif azimuth_type == Constants.CoordAbsolute
      azimuth = relative_azimuth
    end    
    
    # Ensure Azimuth is >=0 and <=360
    if azimuth < 0.0
      azimuth += 360.0
    end

    if azimuth >= 360.0
      azimuth -= 360.0
    end
    
    return azimuth
    
  end
  
  def get_abs_tilt(tilt_type, relative_tilt, highest_roof_pitch, latitude)
  
    if tilt_type == Constants.TiltPitch
      return relative_tilt + highest_roof_pitch
    elsif tilt_type == Constants.TiltLatitude
      return relative_tilt + latitude
    elsif tilt_type == Constants.CoordAbsolute
      return relative_tilt
    end
    
  end
  
end

# register the measure to be used by the application
ResidentialPhotovoltaicsSAM.new.registerWithApplication
