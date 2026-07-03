import Fluent
import Vapor

struct SeedDVSACentres: AsyncMigration {

    // Local model used only within this migration
    private final class DVSACentreRow: Model, @unchecked Sendable {
        static let schema = "dvsa_centres"

        @ID(key: .id) var id: UUID?
        @Field(key: "name") var name: String
        @Field(key: "region") var region: String

        init() {}

        init(name: String, region: String) {
            self.name = name
            self.region = region
        }
    }

    func prepare(on database: Database) async throws {
        try await database.schema("dvsa_centres")
            .id()
            .field("name", .string, .required)
            .field("region", .string, .required)
            .create()

        let centres: [(name: String, region: String)] = [
            // East of England
            ("Basildon", "East of England"),
            ("Bedford", "East of England"),
            ("Bishops Stortford", "East of England"),
            ("Bletchley", "East of England"),
            ("Bury St Edmunds", "East of England"),
            ("Cambridge (Brookmount Court)", "East of England"),
            ("Chelmsford", "East of England"),
            ("Clacton-on-Sea", "East of England"),
            ("Colchester", "East of England"),
            ("Ipswich", "East of England"),
            ("Kings Lynn", "East of England"),
            ("Leighton Buzzard (Stanbridge Road)", "East of England"),
            ("Letchworth", "East of England"),
            ("Lowestoft (Mobbs Way)", "East of England"),
            ("Luton", "East of England"),
            ("Norwich (Peachman Way)", "East of England"),
            ("Peterborough", "East of England"),
            ("Southend-on-Sea", "East of England"),
            ("St Albans", "East of England"),
            ("Stevenage", "East of England"),
            ("Tilbury", "East of England"),
            ("Watford", "East of England"),

            // East Midlands
            ("Ashfield", "East Midlands"),
            ("Boston", "East Midlands"),
            ("Chesterfield", "East Midlands"),
            ("Derby (Alvaston)", "East Midlands"),
            ("Grantham (Somerby)", "East Midlands"),
            ("Grimsby Coldwater", "East Midlands"),
            ("Hinckley", "East Midlands"),
            ("Kettering", "East Midlands"),
            ("Leicester (Cannock Street)", "East Midlands"),
            ("Leicester (Wigston)", "East Midlands"),
            ("Lincoln", "East Midlands"),
            ("Loughborough", "East Midlands"),
            ("Louth", "East Midlands"),
            ("Melton Mowbray", "East Midlands"),
            ("Northampton", "East Midlands"),
            ("Nottingham (Chilwell)", "East Midlands"),
            ("Nottingham (Colwick)", "East Midlands"),
            ("Skegness", "East Midlands"),
            ("Wellingborough", "East Midlands"),
            ("Worksop", "East Midlands"),

            // London
            ("Barnet", "London"),
            ("Belvedere", "London"),
            ("Borehamwood", "London"),
            ("Brentwood", "London"),
            ("Bromley", "London"),
            ("Chertsey", "London"),
            ("Chingford", "London"),
            ("Enfield (Brancroft Way)", "London"),
            ("Enfield (Innova Business Park)", "London"),
            ("Erith", "London"),
            ("Goodmayes", "London"),
            ("Greenford (Horsenden Lane)", "London"),
            ("Hendon", "London"),
            ("Hornchurch", "London"),
            ("Isleworth (Fleming Way)", "London"),
            ("Loughton", "London"),
            ("Mill Hill", "London"),
            ("Mitcham", "London"),
            ("Morden", "London"),
            ("Pinner", "London"),
            ("Sidcup", "London"),
            ("Slough", "London"),
            ("Southall", "London"),
            ("Tolworth", "London"),
            ("Tottenham", "London"),
            ("Uxbridge", "London"),
            ("Wanstead", "London"),
            ("West Wickham", "London"),
            ("Wood Green", "London"),
            ("Yeading", "London"),

            // North-east England
            ("Alnwick", "North-east England"),
            ("Berwick-On-Tweed", "North-east England"),
            ("Blyth", "North-east England"),
            ("Darlington", "North-east England"),
            ("Durham", "North-east England"),
            ("Gateshead", "North-east England"),
            ("Gosforth", "North-east England"),
            ("Hartlepool", "North-east England"),
            ("Hexham", "North-east England"),
            ("Middlesbrough", "North-east England"),
            ("Northallerton", "North-east England"),
            ("Sunderland", "North-east England"),

            // North-west England
            ("Atherton (Manchester)", "North-west England"),
            ("Barrow In Furness", "North-west England"),
            ("Blackburn with Darwen", "North-west England"),
            ("Blackpool", "North-west England"),
            ("Bolton (Manchester)", "North-west England"),
            ("Bredbury (Manchester)", "North-west England"),
            ("Bury (Manchester)", "North-west England"),
            ("Buxton", "North-west England"),
            ("Carlisle", "North-west England"),
            ("Carlisle LGV (Cars)", "North-west England"),
            ("Chadderton", "North-west England"),
            ("Cheetham Hill (Manchester)", "North-west England"),
            ("Chester", "North-west England"),
            ("Chorley", "North-west England"),
            ("Crewe", "North-west England"),
            ("Heysham", "North-west England"),
            ("Kendal (Oxenholme Road)", "North-west England"),
            ("Macclesfield", "North-west England"),
            ("Nelson", "North-west England"),
            ("Northwich", "North-west England"),
            ("Norris Green (Liverpool)", "North-west England"),
            ("Preston", "North-west England"),
            ("Rochdale (Manchester)", "North-west England"),
            ("Sale (Manchester)", "North-west England"),
            ("Southport (Liverpool)", "North-west England"),
            ("Speke (Liverpool)", "North-west England"),
            ("St Helens (Liverpool)", "North-west England"),
            ("Steeton", "North-west England"),
            ("Upton", "North-west England"),
            ("Wallasey", "North-west England"),
            ("Warrington", "North-west England"),
            ("West Didsbury (Manchester)", "North-west England"),
            ("Widnes", "North-west England"),
            ("Workington", "North-west England"),

            // South-east England
            ("Ashford (Kent)", "South-east England"),
            ("Aylesbury", "South-east England"),
            ("Banbury", "South-east England"),
            ("Basingstoke", "South-east England"),
            ("Burgess Hill", "South-east England"),
            ("Canterbury", "South-east England"),
            ("Chichester", "South-east England"),
            ("Crawley", "South-east England"),
            ("Eastbourne", "South-east England"),
            ("Farnborough", "South-east England"),
            ("Folkestone", "South-east England"),
            ("Gillingham", "South-east England"),
            ("Greenham", "South-east England"),
            ("Guildford", "South-east England"),
            ("Hastings (Ore)", "South-east England"),
            ("Herne Bay", "South-east England"),
            ("High Wycombe", "South-east England"),
            ("Lee On The Solent", "South-east England"),
            ("Maidstone", "South-east England"),
            ("Newport (Isle of Wight)", "South-east England"),
            ("Oxford (Cowley)", "South-east England"),
            ("Portsmouth", "South-east England"),
            ("Reading", "South-east England"),
            ("Redhill Aerodrome", "South-east England"),
            ("Sevenoaks", "South-east England"),
            ("Southampton (Maybush)", "South-east England"),
            ("Tunbridge Wells", "South-east England"),
            ("West Wickham", "South-east England"),
            ("Winchester", "South-east England"),
            ("Worthing", "South-east England"),

            // South-west England
            ("Barnstaple", "South-west England"),
            ("Bodmin", "South-west England"),
            ("Bristol (Avonmouth)", "South-west England"),
            ("Bristol (Kingswood)", "South-west England"),
            ("Camborne", "South-west England"),
            ("Cheltenham", "South-west England"),
            ("Chippenham", "South-west England"),
            ("Dorchester", "South-west England"),
            ("Exeter", "South-west England"),
            ("Gloucester", "South-west England"),
            ("Isles of Scilly", "South-west England"),
            ("Launceston", "South-west England"),
            ("Newton Abbot", "South-west England"),
            ("Penzance", "South-west England"),
            ("Plymouth", "South-west England"),
            ("Poole", "South-west England"),
            ("Salisbury", "South-west England"),
            ("Swindon", "South-west England"),
            ("Taunton", "South-west England"),
            ("Trowbridge", "South-west England"),
            ("Weston-super-Mare", "South-west England"),
            ("Yeovil", "South-west England"),

            // West Midlands
            ("Birmingham (Cocks Moors)", "West Midlands"),
            ("Birmingham (Garretts Green)", "West Midlands"),
            ("Birmingham (Kings Heath)", "West Midlands"),
            ("Birmingham (Kingstanding)", "West Midlands"),
            ("Birmingham (Shirley)", "West Midlands"),
            ("Birmingham (South Yardley)", "West Midlands"),
            ("Burton on Trent", "West Midlands"),
            ("Coventry", "West Midlands"),
            ("Dudley", "West Midlands"),
            ("Featherstone", "West Midlands"),
            ("Hereford", "West Midlands"),
            ("Lichfield", "West Midlands"),
            ("Ludlow", "West Midlands"),
            ("Nuneaton", "West Midlands"),
            ("Oswestry", "West Midlands"),
            ("Redditch", "West Midlands"),
            ("Rugby", "West Midlands"),
            ("Shrewsbury", "West Midlands"),
            ("Stafford", "West Midlands"),
            ("Stoke-on-Trent (Cobridge)", "West Midlands"),
            ("Stoke-on-Trent (Newcastle-Under-Lyme)", "West Midlands"),
            ("Telford", "West Midlands"),
            ("Warwick (Wedgenock House)", "West Midlands"),
            ("Wednesbury", "West Midlands"),
            ("Wolverhampton", "West Midlands"),
            ("Worcester", "West Midlands"),

            // Yorkshire and the Humber
            ("Barnsley", "Yorkshire and the Humber"),
            ("Bradford (Heaton)", "Yorkshire and the Humber"),
            ("Bradford (Thornbury)", "Yorkshire and the Humber"),
            ("Bridlington", "Yorkshire and the Humber"),
            ("Doncaster", "Yorkshire and the Humber"),
            ("Grimsby Coldwater", "Yorkshire and the Humber"),
            ("Halifax", "Yorkshire and the Humber"),
            ("Heckmondwike", "Yorkshire and the Humber"),
            ("Horsforth", "Yorkshire and the Humber"),
            ("Huddersfield", "Yorkshire and the Humber"),
            ("Hull", "Yorkshire and the Humber"),
            ("Knaresborough", "Yorkshire and the Humber"),
            ("Leeds (Colton Mill)", "Yorkshire and the Humber"),
            ("Leeds (Fearnville)", "Yorkshire and the Humber"),
            ("Malton", "Yorkshire and the Humber"),
            ("Pontefract", "Yorkshire and the Humber"),
            ("Rotherham", "Yorkshire and the Humber"),
            ("Scarborough", "Yorkshire and the Humber"),
            ("Scunthorpe", "Yorkshire and the Humber"),
            ("Sheffield (Handsworth)", "Yorkshire and the Humber"),
            ("Sheffield (Middlewood Road)", "Yorkshire and the Humber"),
            ("Skipton", "Yorkshire and the Humber"),
            ("Wakefield", "Yorkshire and the Humber"),
            ("Walton LGV", "Yorkshire and the Humber"),
            ("Whitby", "Yorkshire and the Humber"),
            ("York", "Yorkshire and the Humber"),
        ]

        for (name, region) in centres {
            try await DVSACentreRow(name: name, region: region).save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("dvsa_centres").delete()
    }
}
