#see the URL below for information on how to write OpenStudio measures
# http://openstudio.nrel.gov/openstudio-measure-writing-guide

#see the URL below for information on using life cycle cost objects in OpenStudio
# http://openstudio.nrel.gov/openstudio-life-cycle-examples

#see the URL below for access to C++ documentation on model objects (click on "model" in the main window to view model objects)
# http://openstudio.nrel.gov/sites/openstudio.nrel.gov/files/nv_data/cpp_documentation_it/model/html/namespaces.html

require "#{File.dirname(__FILE__)}/resources/util"
require "#{File.dirname(__FILE__)}/resources/constants"
require "#{File.dirname(__FILE__)}/resources/geometry"
require "#{File.dirname(__FILE__)}/resources/hvac"

#start the measure
class ProcessElectricBaseboard < OpenStudio::Ruleset::ModelUserScript
  
  #define the name that a user will see, this method may be deprecated as
  #the display name in PAT comes from the name field in measure.xml
  def name
    return "Set Residential Electric Baseboard"
  end
  
  def description
    return "This measure removes any existing electric baseboards from the building and adds electric baseboards. For multifamily buildings, the electric baseboard can be set for all units of the building."
  end
  
  def modeler_description
    return "Any heating components or baseboard convective electrics/waters are removed from any existing air/plant loops or zones. An HVAC baseboard convective electric is added to the living zone, as well as to the finished basement if it exists."
  end   
  
  #define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new

    #make an argument for entering baseboard efficiency
    baseboardeff = OpenStudio::Ruleset::OSArgument::makeDoubleArgument("efficiency",true)
    baseboardeff.setDisplayName("Efficiency")
    baseboardeff.setUnits("Btu/Btu")
    baseboardeff.setDescription("The efficiency of the electric baseboard.")
    baseboardeff.setDefaultValue(1.0)
    args << baseboardeff

    #make a string argument for baseboard heating output capacity
    cap_display_names = OpenStudio::StringVector.new
    cap_display_names << Constants.SizingAuto
    (5..150).step(5) do |kbtu|
      cap_display_names << kbtu.to_s
    end
    baseboardcap = OpenStudio::Ruleset::OSArgument::makeChoiceArgument("capacity", cap_display_names, true)
    baseboardcap.setDisplayName("Heating Capacity")
    baseboardcap.setDescription("The output heating capacity of the electric baseboard.")
    baseboardcap.setUnits("kBtu/hr")
    baseboardcap.setDefaultValue(Constants.SizingAuto)
    args << baseboardcap
	
    return args
  end #end the arguments method

  #define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    
    #use the built-in error checking 
    if not runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
	
    baseboardEfficiency = runner.getDoubleArgumentValue("efficiency",user_arguments)
    baseboardOutputCapacity = runner.getStringArgumentValue("capacity",user_arguments)
    unless baseboardOutputCapacity == Constants.SizingAuto
      baseboardOutputCapacity = OpenStudio::convert(baseboardOutputCapacity.to_f,"kBtu/h","Btu/h").get
    end
   
    # Remove boiler hot water loop if it exists
    HVAC.remove_hot_water_loop(model, runner)
   
    # Get building units
    units = Geometry.get_building_units(model, runner)
    if units.nil?
        return false
    end
    
    units.each do |unit|
      
      obj_name = Constants.ObjectNameElectricBaseboard(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = HVAC.get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        HVAC.remove_existing_hvac_equipment(model, runner, Constants.ObjectNameElectricBaseboard, control_zone)
      
        htg_coil = OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.new(model)
        htg_coil.setName(obj_name + " #{control_zone.name} convective electric")
        if baseboardOutputCapacity != Constants.SizingAuto
            htg_coil.setNominalCapacity(OpenStudio::convert(baseboardOutputCapacity,"Btu/h","W").get)
        end
        htg_coil.setEfficiency(baseboardEfficiency)

        htg_coil.addToThermalZone(control_zone)
        runner.registerInfo("Added '#{htg_coil.name}' to '#{control_zone.name}' of #{unit.name}")

        slave_zones.each do |slave_zone|
        
          # Remove existing equipment
          HVAC.remove_existing_hvac_equipment(model, runner, Constants.ObjectNameElectricBaseboard, slave_zone)    
        
          htg_coil = OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.new(model)
          htg_coil.setName(obj_name + " #{slave_zone.name} convective electric")
          if baseboardOutputCapacity != Constants.SizingAuto
              htg_coil.setNominalCapacity(OpenStudio::convert(baseboardOutputCapacity,"Btu/h","W").get)
          end
          htg_coil.setEfficiency(baseboardEfficiency)

          htg_coil.addToThermalZone(slave_zone)
          runner.registerInfo("Added '#{htg_coil.name}' to '#{slave_zone.name}' of #{unit.name}")

        end    
      
      end
      
    end
	
    return true
 
  end #end the run method

end #end the measure

#this allows the measure to be use by the application
ProcessElectricBaseboard.new.registerWithApplication